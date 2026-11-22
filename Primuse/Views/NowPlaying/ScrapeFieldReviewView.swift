import SwiftUI
import ImageIO
import PrimuseKit

actor ScrapeReviewImages {
    private let cache = NSCache<NSString, NSData>()
    private var inFlight: [String: Task<Data, Error>] = [:]

    init() { cache.totalCostLimit = 32 * 1024 * 1024 }

    func data(for cover: ScrapeReviewCover) async throws -> Data {
        if let data = cover.data { return data }
        guard let key = cover.url else { throw ScraperError.notFound }
        if let data = cache.object(forKey: key as NSString) { return data as Data }
        if let task = inFlight[key] { return try await task.value }
        let task = Task { try await cover.load() }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        let data = try await task.value
        cache.setObject(data as NSData, forKey: key as NSString, cost: data.count)
        return data
    }

    func thumbnail(for cover: ScrapeReviewCover) async throws -> CGImage {
        try await preview(for: cover).image
    }

    /// 缩略图加原图的像素尺寸和字节数（选封面时看得出哪张更清楚）。
    func preview(for cover: ScrapeReviewCover) async throws -> (image: CGImage, pixelSize: CGSize?, byteCount: Int) {
        let data = try await data(for: cover)
        try Task.checkCancellation()
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 620
              ] as CFDictionary) else { throw ScraperError.notFound }
        var pixelSize: CGSize?
        if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = properties[kCGImagePropertyPixelWidth] as? Int,
           let height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0 {
            let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
            pixelSize = orientation >= 5 ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
        }
        return (image, pixelSize, data.count)
    }
}

struct ScrapeFieldReviewView<OriginalCover: View>: View {
    @Binding var draft: ScrapeReviewDraft
    let images: ScrapeReviewImages
    @ViewBuilder var originalCover: () -> OriginalCover
    /// 「当前」歌词怎么取。iPhone、Mac 传进来按播放时的顺序读（缓存、歌旁边的歌词文件、内嵌），不走在线兜底；
    /// 不传时只读缓存和资料库里的歌词文本。
    var loadsOriginalLyrics: (@MainActor () async -> [LyricLine])? = nil
    @State private var originalLyrics: ScrapeReviewLyrics?
    @State private var fullLyrics: ScrapeReviewLyrics?
    /// 补拉记录跟着这次搜索走，换了搜索词就重来。
    @State private var followUpSessionID: UUID?
    @State private var requestedDetails: Set<String> = []
    @State private var loadingCandidateID: String?
    @State private var searchedLyrics: Set<String> = []
    @State private var refreshingLyrics = false
    #if os(macOS)
    /// 方向键翻的是最近点过的那一项。
    @State private var activeField: ScrapeField?
    @FocusState private var acceptsArrowKeys: Bool
    #endif

    private var fieldSpacing: CGFloat {
        #if os(tvOS)
        18
        #else
        24
        #endif
    }

    var body: some View {
        let currentContext = ScrapeReviewContext(song: draft.original)
        VStack(alignment: .leading, spacing: fieldSpacing) {
            ForEach(draft.fields, id: \.self) { field in
                #if os(tvOS)
                ScrapeReviewFieldRow(field: field, options: draft.choices(for: field), selected: selection(for: field),
                    originalText: field.text(in: draft.original.scrapeFields), originalLyrics: originalLyrics,
                    currentContext: currentContext, busyNote: busyNote(for: field),
                    images: images, showLyrics: { fullLyrics = $0 }, originalCover: originalCover)
                #else
                ScrapeReviewFieldPicker(field: field, options: draft.choices(for: field), selected: selection(for: field),
                    originalText: field.text(in: draft.original.scrapeFields), originalLyrics: originalLyrics,
                    currentContext: currentContext, busyNote: busyNote(for: field),
                    images: images, showLyrics: { fullLyrics = $0 }, originalCover: originalCover)
                #endif
            }
        }
        #if os(macOS)
        .focusable()
        .focusEffectDisabled()
        .focused($acceptsArrowKeys)
        .onKeyPress(phases: [.down, .repeat]) { press in stepActiveField(press) }
        #endif
        .task(id: draft.original.id) { await loadOriginalLyrics() }
        .task(id: draft.selected) { await fetchSelectedDetails() }
        .task(id: lyricsLookupKey) { await refreshLyricsForSelection() }
        .sheet(isPresented: Binding(get: { fullLyrics != nil }, set: { if !$0 { fullLyrics = nil } })) {
            NavigationStack {
                ScrollView {
                    if let fullLyrics { ScrapeReviewLyricLines(lyrics: fullLyrics, expanded: true).padding() }
                }
                #if os(tvOS)
                // 只有文字的全文，要让焦点能停上去，遥控器才滑得动。
                .tvReadOnlyScrollFocus()
                #endif
                .navigationTitle("scrape_lyrics_preview")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("done") { fullLyrics = nil } } }
            }
            #if os(macOS)
            .frame(minWidth: 420, minHeight: 360)
            #elseif os(tvOS)
            .onExitCommand { fullLyrics = nil }
            #endif
        }
    }

    private func selection(for field: ScrapeField) -> Binding<String?> {
        Binding(get: { draft.selected[field] }, set: { id in
            draft.select(id, for: field)
            #if os(macOS)
            activeField = field
            acceptsArrowKeys = true
            #endif
        })
    }

    /// 字段标题旁边的进行中说明：正在补拉选中候选的详情，或正在按所选信息找歌词。
    private func busyNote(for field: ScrapeField) -> LocalizedStringKey? {
        if field == .lyrics, refreshingLyrics { return "scrape_review_lyrics_refreshing" }
        if let loadingCandidateID, draft.choice(for: field)?.candidate?.id == loadingCandidateID {
            return "scrape_candidate_loading_details"
        }
        return nil
    }

    private func loadOriginalLyrics() async {
        guard draft.requests(.lyrics) else { return }
        let song = draft.original
        if let loadsOriginalLyrics {
            let lines = await loadsOriginalLyrics()
            guard !Task.isCancelled else { return }
            originalLyrics = lines.isEmpty ? nil : .init(lines)
            plog("🔍 Scrape review current lyrics: lines=\(lines.count)")
            return
        }
        if let lines = await MetadataAssetStore.shared.cachedLyrics(forSongID: song.id), !Task.isCancelled {
            originalLyrics = .init(lines)
        } else if let text = song.lyricsText, !text.isEmpty, !Task.isCancelled {
            originalLyrics = .init(LyricsContentParser.parseText(text), raw: text)
        }
    }

    /// 换了一次搜索（草稿整个换掉）就把补拉记录清掉。
    private func syncFollowUpSession() -> ScrapeReviewSession? {
        guard let session = draft.catalog.session else { return nil }
        if followUpSessionID != session.id {
            followUpSessionID = session.id
            requestedDetails = []
            searchedLyrics = [ScraperManager.reviewLookupKey(title: session.title, artist: session.artist)]
            loadingCandidateID = nil
            refreshingLyrics = false
        }
        return session
    }

    /// 选中了一条只拿到搜索行字段的候选：补拉这一条的详情，详情里的字段和封面并进各字段的选项。
    private func fetchSelectedDetails() async {
        guard let session = syncFollowUpSession() else { return }
        let fields = Set(ScrapeField.allCases.filter { draft.requests($0) })
        for candidate in draft.selectedCandidatesWithoutDetail where !requestedDetails.contains(candidate.id) {
            requestedDetails.insert(candidate.id)
            loadingCandidateID = candidate.id
            let more = await session.manager.reviewDetail(for: candidate, fields: fields)
            if loadingCandidateID == candidate.id { loadingCandidateID = nil }
            guard !Task.isCancelled else {
                // 被下一次改选打断：还选着它的话下一轮再拉。
                requestedDetails.remove(candidate.id)
                return
            }
            draft.merge(more, from: session)
        }
    }

    private var lyricsLookupKey: String {
        let lookup = draft.lyricsLookup
        return ScraperManager.reviewLookupKey(title: lookup.title, artist: lookup.artist)
    }

    /// 标题或歌手改选成别的候选的值：停一下（左右翻选项时不每翻一下就找一次），按所选的歌名、歌手补找歌词，
    /// 新找到的加进歌词选项，已有的和已经选中的那份都留着。找过的身份不再找。
    private func refreshLyricsForSelection() async {
        refreshingLyrics = false
        guard draft.requests(.lyrics), let session = syncFollowUpSession() else { return }
        let lookup = draft.lyricsLookup
        let key = ScraperManager.reviewLookupKey(title: lookup.title, artist: lookup.artist)
        guard draft.isEdited(.title) || draft.isEdited(.artist) else {
            // 刚打开时的默认勾选不算改选：这份身份当作已经找过。
            searchedLyrics.insert(key)
            return
        }
        guard !searchedLyrics.contains(key) else { return }
        do { try await Task.sleep(for: .milliseconds(700)) } catch { return }
        refreshingLyrics = true
        let duration: TimeInterval? = draft.original.duration > 0 ? draft.original.duration : nil
        let more = await session.manager.reviewLyrics(title: lookup.title, artist: lookup.artist, album: lookup.album,
                                                      duration: duration, settings: session.settings)
        guard !Task.isCancelled else { return }
        refreshingLyrics = false
        searchedLyrics.insert(key)
        draft.merge(more, from: session)
    }

    #if os(macOS)
    /// 左右方向键翻最近点过的那一项的候选，没点过时翻第一项。
    private func stepActiveField(_ press: KeyPress) -> KeyPress.Result {
        let delta: Int
        switch press.key {
        case .leftArrow: delta = -1
        case .rightArrow: delta = 1
        default: return .ignored
        }
        guard let field = activeField ?? draft.fields.first else { return .ignored }
        let ids: [String?] = [nil] + draft.choices(for: field).map { Optional($0.id) }
        let current = ids.firstIndex(of: draft.selected[field]) ?? 0
        let next = current + delta
        guard ids.indices.contains(next) else { return .handled }
        draft.select(ids[next], for: field)
        activeField = field
        return .handled
    }
    #endif
}

private enum ReviewPage: Hashable { case current, option(String) }

/// 选项下面那行副标题：候选有出处就显示它属于哪一首；「当前」显示资料库里这首歌自己的，时长对着看。
/// 从文件里读出来的「本地」结果没有出处，不显示。
private func scrapeReviewSubtitle(_ option: ScrapeReviewOption?, field: ScrapeField,
                                  current: ScrapeReviewContext) -> String? {
    guard let option else { return current.subtitle(for: field) }
    return option.context?.subtitle(for: field)
}

#if os(tvOS)
/// 电视上用遥控器左右键逐页切换，保留整页卡片加上一个/下一个。
private struct ScrapeReviewFieldRow<OriginalCover: View>: View {
    let field: ScrapeField
    let options: [ScrapeReviewOption]
    @Binding var selected: String?
    let originalText: String?
    let originalLyrics: ScrapeReviewLyrics?
    let currentContext: ScrapeReviewContext
    let busyNote: LocalizedStringKey?
    let images: ScrapeReviewImages
    let showLyrics: (ScrapeReviewLyrics) -> Void
    @ViewBuilder var originalCover: () -> OriginalCover

    private var pages: [ReviewPage] { [.current] + options.map { .option($0.id) } }
    private var page: Binding<ReviewPage> {
        Binding(get: { selected.map(ReviewPage.option) ?? .current }, set: {
            switch $0 { case .current: selected = nil; case .option(let id): selected = id }
        })
    }
    private var index: Int { pages.firstIndex(of: page.wrappedValue) ?? 0 }
    @ScaledMetric(relativeTo: .body) private var textHeight: CGFloat = 70
    @ScaledMetric(relativeTo: .body) private var lyricsHeight: CGFloat = 182
    private var height: CGFloat {
        #if os(tvOS)
        // 文字页多一行副标题（专辑、年份、时长），留出一行的高度；都含上下各 16 的内边距。
        switch field { case .cover: 316; case .lyrics: 366; default: 138 }
        #else
        switch field { case .cover: 184; case .lyrics: lyricsHeight; default: textHeight }
        #endif
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(field.label).font(.headline)
                if let busyNote {
                    ProgressView()
                    Text(busyNote).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if !options.isEmpty {
                    stepButton(-1)
                    Text(verbatim: "\(index + 1) / \(pages.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    stepButton(1)
                }
            }
            #if os(tvOS)
            content(page.wrappedValue).id(page.wrappedValue)
            #elseif os(iOS)
            TabView(selection: page) {
                ForEach(pages, id: \.self) { item in content(item).tag(item) }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(height: height)
            #else
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(pages, id: \.self) { item in content(item).containerRelativeFrame(.horizontal).id(item) }
                }.scrollTargetLayout()
            }
            .frame(height: height)
            .scrollIndicators(.hidden)
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: Binding<ReviewPage?>(get: { page.wrappedValue }, set: { if let next = $0 { page.wrappedValue = next } }))
            #endif
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("scrape.review." + field.rawValue)
    }

    private func stepButton(_ delta: Int) -> some View {
        Button {
            let next = index + delta
            if pages.indices.contains(next) { page.wrappedValue = pages[next] }
        } label: {
            Image(systemName: delta < 0 ? "chevron.left" : "chevron.right")
                .font(.body.weight(.semibold)).frame(minWidth: 36, minHeight: 34)
                .contentShape(Rectangle())
        }
        #if !os(tvOS)
        .buttonStyle(.borderless)
        #endif
        .accessibilityLabel(delta < 0 ? Text("scrape_review_previous") : Text("scrape_review_next"))
        .accessibilityIdentifier("scrape.review." + field.rawValue + (delta < 0 ? ".previous" : ".next"))
        .disabled(!pages.indices.contains(index + delta))
    }

    @ViewBuilder private func content(_ page: ReviewPage) -> some View {
        let option = options.first { .option($0.id) == page }
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                if let source = option?.source {
                    Text(verbatim: source).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                } else {
                    Text(page == .current ? "scrape_review_keep" : "cat_local").font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if field == .lyrics, let lyrics = lyricChoice(option) {
                    Button("scrape_lyrics_preview") { showLyrics(lyrics) }.font(.caption)
                        .accessibilityIdentifier("scrape.review.lyrics.preview")
                    #if !os(tvOS)
                    .buttonStyle(.borderless)
                    #endif
                }
            }
            // 这一项属于哪一首（「当前」是资料库里这首歌自己的），时长对着看就分得清。
            if let subtitle = scrapeReviewSubtitle(option, field: field, current: currentContext) {
                Text(verbatim: subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            switch option?.value {
            case .text(let value):
                Text(verbatim: value).font(.body).lineLimit(1)
            case .cover(let cover):
                ScrapeReviewCoverImage(cover: cover, images: images)
            case .lyrics(let lyrics):
                ScrapeReviewLyricLines(lyrics: lyrics, expanded: false)
            case nil:
                switch field {
                case .cover: originalCover().frame(maxWidth: .infinity, maxHeight: .infinity)
                case .lyrics:
                    if let originalLyrics { ScrapeReviewLyricLines(lyrics: originalLyrics, expanded: false) }
                    else { Text(verbatim: "—").foregroundStyle(.secondary) }
                default: Text(verbatim: originalText ?? "—").lineLimit(2)
                }
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.quaternary.opacity(0.65), in: RoundedRectangle(cornerRadius: TVRadius.card, style: .continuous))
        .frame(height: height)
    }

    private func lyricChoice(_ option: ScrapeReviewOption?) -> ScrapeReviewLyrics? {
        if case .lyrics(let lyrics) = option?.value { return lyrics }
        return option == nil ? originalLyrics : nil
    }
}
#endif

/// 封面原图的尺寸和字节数。
private struct ScrapeReviewCoverMeta: Equatable {
    var pixelSize: CGSize?
    var byteCount: Int

    /// 「2400×2400 · 612 KB」，尺寸读不出来时只写大小。
    var label: String {
        let size = ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
        guard let pixelSize else { return size }
        let width = Int(pixelSize.width)
        let height = Int(pixelSize.height)
        return "\(width)×\(height) · \(size)"
    }
}

private struct ScrapeReviewCoverImage: View {
    let cover: ScrapeReviewCover
    let images: ScrapeReviewImages
    /// 铺满方框（封面轮播）还是完整显示（电视）。
    var fills = false
    /// 读到原图时报出它的尺寸和字节数（封面流卡片上显示「宽×高 · 大小」）。
    var onLoaded: ((ScrapeReviewCoverMeta) -> Void)? = nil
    @State private var image: CGImage?
    @State private var failed = false
    @State private var attempt = 0

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1).resizable()
                    .aspectRatio(contentMode: fills ? .fill : .fit)
            }
            else if failed { Button("retry") { attempt += 1 } }
            else { ProgressView() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: attempt) {
            failed = false
            do {
                let result = try await images.preview(for: cover)
                guard !Task.isCancelled else { return }
                image = result.image
                onLoaded?(ScrapeReviewCoverMeta(pixelSize: result.pixelSize, byteCount: result.byteCount))
            }
            catch { if !Task.isCancelled { failed = true } }
        }
    }
}

private struct ScrapeReviewLyricLines: View {
    let lyrics: ScrapeReviewLyrics
    let expanded: Bool
    /// 收起时露出几行。
    var previewLineCount = 4
    /// 收起时歌词不到 previewLineCount 行也占满这么高：横排的几张卡片一样高，换一张时下面的内容不跳。
    var reservesPreviewSpace = false

    var body: some View {
        let shown = expanded ? lyrics.lines.count : min(previewLineCount, lyrics.lines.count)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(verbatim: summary)
                if let format = lyrics.format { Text(verbatim: format) }
                if lyrics.lines.contains(where: { $0.manualTranslation != nil }) { Text("lyrics_translation_section") }
            }
            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            .lineLimit(expanded ? nil : 1)
            ForEach(Array(lyrics.lines.prefix(shown).enumerated()), id: \.offset) { _, line in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    if line.isSynchronized {
                        let seconds = Int(min(864_000, max(0, line.timestamp.isFinite ? line.timestamp : 0)))
                        Text(verbatim: String(format: "%d:%02d", seconds / 60, seconds % 60)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading) {
                        Text(verbatim: line.text).lineLimit(expanded ? nil : 1)
                        if expanded, let translation = line.manualTranslation { Text(verbatim: translation.text).font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
            if reservesPreviewSpace && !expanded && shown < previewLineCount {
                ForEach(shown..<previewLineCount, id: \.self) { _ in
                    Text(verbatim: " ").hidden()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var summary: String {
        let count = lyrics.summary.lineCount
        if lyrics.summary.isWordLevel { return String(localized: "lyrics_sources_summary_word \(count)") }
        if lyrics.summary.isSynchronized { return String(localized: "lyrics_sources_summary_line \(count)") }
        return String(localized: "lyrics_sources_summary_plain \(count)")
    }
}

// MARK: - 来源角标

/// 每个刮削源一个颜色的小角标，放在封面、选项和歌词卡片里面的左上角，正文区域留给内容本身。
/// 「当前」是库里现在的值，「本地」是从文件里读出来的结果。源名太长时在卡片里面用省略号收住，不撑出卡片。
struct ScrapeSourceBadge: View {
    enum Kind: Equatable {
        case current
        case local
        case source(String)
    }

    let kind: Kind

    init(option: ScrapeReviewOption?) {
        if let option {
            kind = option.source.map(Kind.source) ?? .local
        } else {
            kind = .current
        }
    }

    var body: some View {
        Text(verbatim: title)
            .font(.caption2.weight(.bold))
            .lineLimit(1)
            .truncationMode(.tail)
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.gradient))
            .overlay { Capsule().strokeBorder(.white.opacity(0.22), lineWidth: 0.5) }
            .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
    }

    private var title: String {
        switch kind {
        case .current: String(localized: "scrape_badge_current")
        case .local: String(localized: "cat_local")
        case .source(let name): name
        }
    }

    private var color: Color {
        switch kind {
        case .current: Color(white: 0.48)
        case .local: Color(red: 0.2, green: 0.55, blue: 0.62)
        case .source(let name): ScrapeSourcePalette.color(for: name)
        }
    }
}

/// 来源名对应的颜色：内置源和导入时带了颜色的源用它们自己的颜色，常见平台按品牌色，
/// 其余按名字稳定地分到一组颜色里（同一个源每次都是同一个颜色）。
enum ScrapeSourcePalette {
    static func color(for name: String) -> Color {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let type = MusicScraperType.builtInOrder.first(where: { $0.displayName == trimmed }) {
            return type.themeColor
        }
        if let config = ScraperConfigStore.shared.allConfigs.first(where: { $0.name == trimmed }),
           let hex = config.color, !hex.isEmpty {
            return Color(hex: hex)
        }
        let key = trimmed.lowercased()
        for (needles, color) in brands where needles.contains(where: { key.contains($0) }) {
            return color
        }
        var hash: UInt32 = 2_166_136_261
        for scalar in key.unicodeScalars {
            hash = (hash ^ scalar.value) &* 16_777_619
        }
        return fallback[Int(hash % UInt32(fallback.count))]
    }

    private static let brands: [([String], Color)] = [
        (["网易", "netease", "163"], Color(red: 0.87, green: 0.15, blue: 0.17)),
        (["qq"], Color(red: 0.11, green: 0.69, blue: 0.4)),
        (["酷狗", "kugou"], Color(red: 0.13, green: 0.52, blue: 0.95)),
        (["酷我", "kuwo"], Color(red: 0.96, green: 0.6, blue: 0.08)),
        (["咪咕", "migu"], Color(red: 0.86, green: 0.07, blue: 0.5)),
        (["千千", "qianqian", "百度"], Color(red: 0.93, green: 0.36, blue: 0.2)),
        (["spotify"], Color(red: 0.11, green: 0.73, blue: 0.33)),
        (["genius"], Color(red: 0.8, green: 0.68, blue: 0.08)),
        (["musixmatch"], Color(red: 0.95, green: 0.3, blue: 0.27)),
        (["deezer"], Color(red: 0.6, green: 0.27, blue: 0.95)),
    ]

    private static let fallback: [Color] = [
        Color(red: 0.36, green: 0.42, blue: 0.95),
        Color(red: 0.16, green: 0.6, blue: 0.62),
        Color(red: 0.85, green: 0.42, blue: 0.16),
        Color(red: 0.62, green: 0.32, blue: 0.86),
        Color(red: 0.2, green: 0.58, blue: 0.3),
        Color(red: 0.82, green: 0.24, blue: 0.45),
        Color(red: 0.25, green: 0.5, blue: 0.75),
        Color(red: 0.62, green: 0.5, blue: 0.2),
    ]
}

#if !os(tvOS)
// MARK: - iPhone、iPad、Mac：横向铺开直接选

/// 一个字段的所有候选。标题右边是「第几个 / 共几个」；封面是斜着叠放的封面流、居中正对的就是选中的，
/// 文字字段是一排可横滑的选项、点哪个选哪个，歌词是一张张大卡片轮转、两侧露出一点下一张。
private struct ScrapeReviewFieldPicker<OriginalCover: View>: View {
    let field: ScrapeField
    let options: [ScrapeReviewOption]
    @Binding var selected: String?
    let originalText: String?
    let originalLyrics: ScrapeReviewLyrics?
    let currentContext: ScrapeReviewContext
    let busyNote: LocalizedStringKey?
    let images: ScrapeReviewImages
    let showLyrics: (ScrapeReviewLyrics) -> Void
    @ViewBuilder var originalCover: () -> OriginalCover

    private var pages: [ReviewPage] { [.current] + options.map { .option($0.id) } }
    private var page: Binding<ReviewPage> {
        Binding(get: { selected.map(ReviewPage.option) ?? .current }, set: {
            switch $0 { case .current: selected = nil; case .option(let id): selected = id }
        })
    }
    private var index: Int { pages.firstIndex(of: page.wrappedValue) ?? 0 }

    /// 封面流下面那行：正中这张属于哪张专辑、谁的、多长。
    private var coverCaption: String? {
        let option = options.first { .option($0.id) == page.wrappedValue }
        return scrapeReviewSubtitle(option, field: .cover, current: currentContext)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(field.label).font(.headline)
                if let busyNote {
                    ProgressView().controlSize(.mini)
                    Text(busyNote).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                #if os(macOS)
                if !options.isEmpty { stepButton(-1) }
                #endif
                if !options.isEmpty {
                    Text(verbatim: "\(index + 1) / \(pages.count)")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(.fill.tertiary))
                        .contentTransition(.numericText())
                        .animation(.snappy(duration: 0.22), value: index)
                        .accessibilityIdentifier("scrape.review." + field.rawValue + ".position")
                }
                #if os(macOS)
                if !options.isEmpty { stepButton(1) }
                #endif
            }
            switch field {
            case .cover:
                ScrapeReviewCoverFlow(pages: pages, page: page, options: options, images: images,
                                      originalCover: originalCover)
            case .lyrics:
                ScrapeReviewLyricsCarousel(pages: pages, page: page, options: options, originalLyrics: originalLyrics,
                                           currentContext: currentContext, showLyrics: showLyrics)
            default:
                ScrapeReviewTextStrip(field: field, pages: pages, page: page, options: options,
                                      originalText: originalText, currentContext: currentContext)
            }
            if field == .cover, let coverCaption {
                Text(verbatim: coverCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("scrape.review.cover.caption")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("scrape.review." + field.rawValue)
    }

    #if os(macOS)
    /// Mac 上横排的候选多了用鼠标也翻得过去：标题栏右边的上一个 / 下一个。
    private func stepButton(_ delta: Int) -> some View {
        let next = index + delta
        return Button {
            if pages.indices.contains(next) { page.wrappedValue = pages[next] }
        } label: {
            Image(systemName: delta < 0 ? "chevron.left" : "chevron.right")
                .font(.caption.weight(.semibold))
                .frame(width: 22, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(!pages.indices.contains(next))
        .help(delta < 0 ? Text("scrape_review_previous") : Text("scrape_review_next"))
        .accessibilityLabel(delta < 0 ? Text("scrape_review_previous") : Text("scrape_review_next"))
        .accessibilityIdentifier("scrape.review." + field.rawValue + (delta < 0 ? ".previous" : ".next"))
    }
    #endif
}

/// 页面左右各 16pt 的边距，横滑的一排要铺到屏幕边上，滑出去的不在边距处被切断。
private let scrapeReviewPageInset: CGFloat = 16

/// 封面、文字选项、歌词三种卡片共用的圆角。
private let scrapeReviewCardRadius: CGFloat = 16

/// 文字选项和歌词卡片共用的底：没选中是浅灰底加一圈细线，选中换成淡主题色底加主题色描边。
private struct ScrapeReviewCardStyle: ViewModifier {
    let isSelected: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: scrapeReviewCardRadius, style: .continuous)
        content
            .background(shape.fill(isSelected ? AnyShapeStyle(.tint.opacity(0.1)) : AnyShapeStyle(.fill.tertiary)))
            .overlay {
                shape.strokeBorder(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.primary.opacity(0.08)),
                                   lineWidth: isSelected ? 1.5 : 0.5)
            }
    }
}

private extension View {
    /// 横滑的一排在页面左右边距那一段淡出：停稳时卡片都在边距以内、不受影响；滑到一半的、
    /// 屏幕边上露出来的那张淡进边缘，不在边上硬切出半截字。要加在负边距之前，遮罩才盖得到边距那一段。
    func scrapeReviewEdgeFade() -> some View {
        mask {
            HStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                    .frame(width: scrapeReviewPageInset)
                Color.black
                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: scrapeReviewPageInset)
            }
        }
    }
}

/// 封面流：居中那张正对、就是选中的；两侧的缩小、朝中间转开、压暗，叠在居中那张后面，
/// 滑过去或点一下就转到正中。和首页顶部的封面轮播同一种观感。
private struct ScrapeReviewCoverFlow<OriginalCover: View>: View {
    let pages: [ReviewPage]
    @Binding var page: ReviewPage
    let options: [ScrapeReviewOption]
    let images: ScrapeReviewImages
    @ViewBuilder var originalCover: () -> OriginalCover

    @State private var scrolled: ReviewPage?
    @State private var width: CGFloat = 0
    @State private var coverMeta: [ReviewPage: ScrapeReviewCoverMeta] = [:]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var side: CGFloat {
        guard width > 0 else { return 184 }
        return min(max((width * 0.5).rounded(), 140), 236)
    }

    var body: some View {
        let side = side
        let step = (side * 0.66).rounded()
        let reducesMotion = reduceMotion
        let centered = scrolled ?? page
        let centerIndex = pages.firstIndex(of: centered) ?? 0
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: step - side) {
                    ForEach(Array(pages.enumerated()), id: \.element) { offset, item in
                        card(item, side: side, isCentered: item == centered, isTrailingSide: offset > centerIndex)
                            .visualEffect { content, geometry in
                                scrapeCoverFlowEffect(
                                    content,
                                    offsetFromCenter: scrapeReviewOffsetFromCenter(geometry),
                                    step: step,
                                    reduceMotion: reducesMotion
                                )
                            }
                            .zIndex(-Double(abs(offset - centerIndex)))
                            .onTapGesture { select(item) }
                            .id(item)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
            .contentMargins(.horizontal, max(0, (width + scrapeReviewPageInset * 2 - side) / 2), for: .scrollContent)
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: $scrolled, anchor: .center)
            .padding(.horizontal, -scrapeReviewPageInset)
            .frame(height: side + 24)
            .onChange(of: scrolled) { _, new in
                if let new, new != page { page = new }
            }
            .onChange(of: page) { _, new in
                guard scrolled != new else { return }
                withAnimation(.snappy(duration: 0.3)) { scrolled = new }
            }
            // scrollPosition 的初值不会把横向滚动视图滚过去，量到宽度后再滚一次。
            .task(id: width > 0) {
                guard width > 0 else { return }
                await Task.yield()
                proxy.scrollTo(page, anchor: .center)
                scrolled = page
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .accessibilityAdjustableAction { direction in
            let next = (pages.firstIndex(of: page) ?? 0) + (direction == .increment ? 1 : -1)
            if pages.indices.contains(next) { select(pages[next]) }
        }
    }

    /// 右侧的卡片靠中间那一边压在居中封面下面，角标和尺寸放到外侧那一边。
    private func card(_ item: ReviewPage, side: CGFloat, isCentered: Bool, isTrailingSide: Bool) -> some View {
        let option = options.first { .option($0.id) == item }
        let shape = RoundedRectangle(cornerRadius: scrapeReviewCardRadius, style: .continuous)
        let resolution = coverMeta[item].map { meta in
            Text(verbatim: meta.label)
                .font(.caption2.weight(.semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(.black.opacity(0.45)))
        }
        return ZStack {
            shape.fill(.fill.tertiary)
            if case .cover(let cover) = option?.value {
                ScrapeReviewCoverImage(cover: cover, images: images, fills: true) { meta in
                    coverMeta[item] = meta
                }
            } else {
                originalCover()
            }
        }
        .frame(width: side, height: side)
        .clipShape(shape)
        .overlay { shape.fill(Color.black.opacity(isCentered ? 0 : 0.2)) }
        .overlay {
            shape.strokeBorder(isCentered ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.primary.opacity(0.08)),
                               lineWidth: isCentered ? 2.5 : 0.5)
        }
        .overlay(alignment: isTrailingSide ? .topTrailing : .topLeading) {
            ScrapeSourceBadge(option: option).padding(8)
        }
        .overlay(alignment: .bottom) {
            HStack(alignment: .bottom) {
                if !isTrailingSide { resolution }
                Spacer(minLength: 0)
                if isTrailingSide { resolution }
                if isCentered {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3.weight(.semibold))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .tint)
                        .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                        .transition(.scale(scale: 0.5).combined(with: .opacity))
                }
            }
            .padding(8)
        }
        .shadow(color: .black.opacity(isCentered ? 0.26 : 0.12), radius: isCentered ? 14 : 8, y: 6)
        .animation(.snappy(duration: 0.24), value: isCentered)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: accessibilityText(option)))
        .accessibilityAddTraits(isCentered ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier(item == .current ? "scrape.review.cover.current" : "scrape.review.cover.option")
    }

    private func accessibilityText(_ option: ScrapeReviewOption?) -> String {
        guard let option else { return String(localized: "scrape_review_keep") }
        return option.source ?? String(localized: "cat_local")
    }

    private func select(_ item: ReviewPage) {
        guard item != page else { return }
        page = item
    }
}

/// 卡片中心离滚动视图中线多远（右边为正）。`bounds(of:)` 给的是换算到这张卡本地坐标的
/// 滚动视图范围，原点已经在 contentMargins 以内，直接拿卡片中点去减。
private func scrapeReviewOffsetFromCenter(_ geometry: GeometryProxy) -> CGFloat {
    guard let bounds = geometry.bounds(of: .scrollView(axis: .horizontal)) else { return 0 }
    return geometry.size.width / 2 - bounds.midX
}

/// 离中间越远：越小、朝中间转开、远处淡出。只缩放和转，不挪位置，点到的就是看到的那张。
/// 写成文件内的自由函数 —— `visualEffect` 的闭包不继承视图的 MainActor 隔离。
private func scrapeCoverFlowEffect(
    _ content: EmptyVisualEffect,
    offsetFromCenter: CGFloat,
    step: CGFloat,
    reduceMotion: Bool
) -> some VisualEffect {
    let position: CGFloat = step > 0 ? offsetFromCenter / step : 0
    let distance: CGFloat = min(abs(position), 4)
    let near: CGFloat = min(distance, 1)
    let far: CGFloat = max(0, min(distance - 1, 1))
    let scale: CGFloat = 1 - 0.22 * near - 0.1 * far
    let turn: CGFloat = max(-1, min(1, position))
    let degrees: Double = reduceMotion ? 0 : Double(turn) * -46
    let opacity: Double = distance <= 2 ? 1 : max(0, Double(3 - distance))
    return content
        .scaleEffect(scale)
        .rotation3DEffect(.degrees(degrees), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
        .opacity(opacity)
}

/// 标题、艺术家、专辑这类文字字段：一排横铺的选项，点哪个选哪个，选中的描边打勾。
/// 每张卡一样宽、一样高：来源角标在卡片里面的第一行，值最多两行、副标题一行，放不下的在卡片里面用省略号收住。
private struct ScrapeReviewTextStrip: View {
    let field: ScrapeField
    let pages: [ReviewPage]
    @Binding var page: ReviewPage
    let options: [ScrapeReviewOption]
    let originalText: String?
    let currentContext: ScrapeReviewContext

    @State private var width: CGFloat = 0
    /// 卡片的常规宽度，跟着文字大小放大；再大也给下一张留出一截露边。
    @ScaledMetric(relativeTo: .body) private var preferredCardWidth: CGFloat = 228

    private static let spacing: CGFloat = 10

    var body: some View {
        let available: CGFloat = width > 0 ? width : 320
        let cardWidth = min(preferredCardWidth, (available * 0.86).rounded())
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: Self.spacing) {
                    ForEach(pages, id: \.self) { item in
                        chip(item, width: cardWidth).id(item)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollIndicators(.hidden)
            .contentMargins(.horizontal, scrapeReviewPageInset, for: .scrollContent)
            .scrollTargetBehavior(.viewAligned)
            .scrapeReviewEdgeFade()
            .padding(.horizontal, -scrapeReviewPageInset)
            // 量到宽度、卡片定了宽以后再把选中的那张滚到中间。
            .task(id: width > 0) {
                guard width > 0 else { return }
                await Task.yield()
                proxy.scrollTo(page, anchor: .center)
            }
            #if os(macOS)
            // 上一个 / 下一个和方向键换了选中项，把它滚到看得见的地方。
            .onChange(of: page) { _, new in
                withAnimation(PMMotion.list.animation) { proxy.scrollTo(new, anchor: .center) }
            }
            #endif
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    private func chip(_ item: ReviewPage, width: CGFloat) -> some View {
        let option = options.first { .option($0.id) == item }
        let isSelected = item == page
        let text: String = {
            if case .text(let value) = option?.value { return value }
            let original = originalText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return original.isEmpty ? "—" : original
        }()
        // 第二行：这个值属于哪一首（歌手 · 专辑 · 年份 · 时长）。放不下时省略中间，时长留在末尾对着看。
        let subtitle = scrapeReviewSubtitle(option, field: field, current: currentContext)
        return Button {
            withAnimation(PMMotion.list.animation) { page = item }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    ScrapeSourceBadge(option: option)
                    Spacer(minLength: 0)
                    // 没选中时对勾也占着位置：选中前后卡片一样高，长源名的角标不会伸到对勾底下。
                    Image(systemName: "checkmark.circle.fill")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.tint)
                        .scaleEffect(isSelected ? 1 : 0.5)
                        .opacity(isSelected ? 1 : 0)
                        .accessibilityHidden(true)
                }
                ZStack(alignment: .topLeading) {
                    // 占位：两行值加一行副标题的高度。每张卡一样高，值短的空白落在卡片底部。
                    VStack(alignment: .leading, spacing: 3) {
                        Text(verbatim: " ").font(.body.weight(.semibold)).lineLimit(2, reservesSpace: true)
                        Text(verbatim: " ").font(.caption)
                    }
                    .hidden()
                    VStack(alignment: .leading, spacing: 3) {
                        Text(verbatim: text)
                            .font(.body.weight(isSelected ? .semibold : .regular))
                            .foregroundStyle(item == .current && originalText == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        if let subtitle {
                            Text(verbatim: subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
            }
            .padding(12)
            .frame(width: width, alignment: .topLeading)
            .modifier(ScrapeReviewCardStyle(isSelected: isSelected))
            .contentShape(RoundedRectangle(cornerRadius: scrapeReviewCardRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: text))
        .accessibilityHint(Text(verbatim: subtitle ?? ""))
        .accessibilityValue(Text(verbatim: option == nil ? String(localized: "scrape_review_keep") : (option?.source ?? String(localized: "cat_local"))))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("scrape.review." + field.rawValue + ".option")
    }
}

/// 歌词：一张张大卡片轮转，居中的那张就是选中的。卡片和页面上别的内容左右对齐、一次一张，
/// 相邻的那张停在屏幕外、滑动时才进来，不在两边露出被切开的窄条；还有几张看标题右边的「第几个 / 共几个」。
private struct ScrapeReviewLyricsCarousel: View {
    let pages: [ReviewPage]
    @Binding var page: ReviewPage
    let options: [ScrapeReviewOption]
    let originalLyrics: ScrapeReviewLyrics?
    let currentContext: ScrapeReviewContext
    let showLyrics: (ScrapeReviewLyrics) -> Void

    @State private var scrolled: ReviewPage?
    @State private var width: CGFloat = 0
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        // 卡片和页面正文一样宽；卡片间距等于页面边距，停稳时相邻的那张刚好在屏幕外。
        let cardWidth = max(160, width)
        let step = cardWidth + scrapeReviewPageInset
        // 卡片高度跟着内容走（每张都按这么多行占位），字放大到辅助字号时少露几行。
        let previewLines = dynamicTypeSize.isAccessibilitySize ? 3 : 5
        let centered = scrolled ?? page
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: scrapeReviewPageInset) {
                    ForEach(pages, id: \.self) { item in
                        card(item, isCentered: item == centered, previewLines: previewLines)
                            .frame(width: cardWidth)
                            .visualEffect { content, geometry in
                                scrapeLyricsCarouselEffect(
                                    content,
                                    offsetFromCenter: scrapeReviewOffsetFromCenter(geometry),
                                    step: step
                                )
                            }
                            .id(item)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollIndicators(.hidden)
            .contentMargins(.horizontal, scrapeReviewPageInset, for: .scrollContent)
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: $scrolled, anchor: .center)
            .scrapeReviewEdgeFade()
            .padding(.horizontal, -scrapeReviewPageInset)
            .onChange(of: scrolled) { _, new in
                if let new, new != page { page = new }
            }
            .onChange(of: page) { _, new in
                guard scrolled != new else { return }
                withAnimation(.snappy(duration: 0.3)) { scrolled = new }
            }
            .task(id: width > 0) {
                guard width > 0 else { return }
                await Task.yield()
                proxy.scrollTo(page, anchor: .center)
                scrolled = page
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .accessibilityAdjustableAction { direction in
            let next = (pages.firstIndex(of: page) ?? 0) + (direction == .increment ? 1 : -1)
            if pages.indices.contains(next) { page = pages[next] }
        }
    }

    private func card(_ item: ReviewPage, isCentered: Bool, previewLines: Int) -> some View {
        let option = options.first { .option($0.id) == item }
        let lyrics: ScrapeReviewLyrics? = {
            if case .lyrics(let value) = option?.value { return value }
            return option == nil ? originalLyrics : nil
        }()
        // 这份歌词是按哪一首找到的，时长和「当前」那张卡上这首歌的时长对着看。
        let subtitle = scrapeReviewSubtitle(option, field: .lyrics, current: currentContext)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ScrapeSourceBadge(option: option)
                Spacer(minLength: 8)
                if let lyrics {
                    Button { showLyrics(lyrics) } label: {
                        Label("scrape_lyrics_preview", systemImage: "arrow.up.left.and.arrow.down.right")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.borderless)
                    .fixedSize()
                    .accessibilityIdentifier(isCentered ? "scrape.review.lyrics.preview" : "scrape.review.lyrics.preview.side")
                }
            }
            // 没有出处时也占住这一行，几张卡一样高。放不下时省略中间，时长留在末尾。
            Text(verbatim: subtitle ?? " ")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .accessibilityHidden(subtitle == nil)
            if let lyrics {
                ScrapeReviewLyricLines(lyrics: lyrics, expanded: false, previewLineCount: previewLines,
                                       reservesPreviewSpace: true)
            } else {
                // 「当前」没有歌词：占住和别的卡一样的高度，中间写一句暂无歌词。
                ScrapeReviewLyricLines(lyrics: ScrapeReviewLyrics([]), expanded: false, previewLineCount: previewLines,
                                       reservesPreviewSpace: true)
                    .hidden()
                    .overlay {
                        Text("no_lyrics").font(.subheadline).foregroundStyle(.secondary)
                    }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .modifier(ScrapeReviewCardStyle(isSelected: isCentered))
        .animation(PMMotion.list.animation, value: isCentered)
        .contentShape(RoundedRectangle(cornerRadius: scrapeReviewCardRadius, style: .continuous))
        .onTapGesture {
            guard item != page else { return }
            page = item
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(isCentered ? .isSelected : [])
    }
}

/// 歌词卡片离开正中时稍微缩小、变淡，滑动时有轮转的感觉。
private func scrapeLyricsCarouselEffect(
    _ content: EmptyVisualEffect,
    offsetFromCenter: CGFloat,
    step: CGFloat
) -> some VisualEffect {
    let distance: CGFloat = step > 0 ? min(abs(offsetFromCenter) / step, 1) : 0
    return content
        .scaleEffect(1 - 0.06 * distance)
        .opacity(1 - 0.35 * Double(distance))
}
#endif
