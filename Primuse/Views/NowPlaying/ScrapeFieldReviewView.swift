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
        let data = try await data(for: cover)
        try Task.checkCancellation()
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 620
              ] as CFDictionary) else { throw ScraperError.notFound }
        return image
    }
}

struct ScrapeFieldReviewView<OriginalCover: View>: View {
    @Binding var draft: ScrapeReviewDraft
    let images: ScrapeReviewImages
    @ViewBuilder var originalCover: () -> OriginalCover
    @State private var originalLyrics: ScrapeReviewLyrics?
    @State private var fullLyrics: ScrapeReviewLyrics?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(draft.fields, id: \.self) { field in
                ScrapeReviewFieldRow(field: field, options: draft.choices(for: field),
                    selected: Binding(get: { draft.selected[field] }, set: { draft.select($0, for: field) }),
                    originalText: field.text(in: draft.original.scrapeFields), originalLyrics: originalLyrics,
                    images: images, showLyrics: { fullLyrics = $0 }, originalCover: originalCover)
            }
        }
        .task(id: draft.original.id) {
            guard draft.fields.contains(.lyrics) else { return }
            let song = draft.original
            if let lines = await MetadataAssetStore.shared.cachedLyrics(forSongID: song.id), !Task.isCancelled {
                originalLyrics = .init(lines)
            } else if let text = song.lyricsText, !text.isEmpty, !Task.isCancelled {
                originalLyrics = .init(LyricsContentParser.parseText(text), raw: text)
            }
        }
        .sheet(isPresented: Binding(get: { fullLyrics != nil }, set: { if !$0 { fullLyrics = nil } })) {
            NavigationStack {
                ScrollView {
                    if let fullLyrics { ScrapeReviewLyricLines(lyrics: fullLyrics, expanded: true).padding() }
                }
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
}

private enum ReviewPage: Hashable { case current, option(String) }

private struct ScrapeReviewFieldRow<OriginalCover: View>: View {
    let field: ScrapeField
    let options: [ScrapeReviewOption]
    @Binding var selected: String?
    let originalText: String?
    let originalLyrics: ScrapeReviewLyrics?
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
        switch field { case .cover: 280; case .lyrics: 330; default: 86 }
        #else
        switch field { case .cover: 184; case .lyrics: lyricsHeight; default: textHeight }
        #endif
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(field.label).font(.headline)
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
                    Text(verbatim: source).font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(page == .current ? "scrape_review_keep" : "cat_local").font(.caption).foregroundStyle(.secondary)
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
            switch option?.value {
            case .text(let value):
                Text(verbatim: value).font(.body).lineLimit(2)
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
        .padding(.horizontal, 14).padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.quaternary.opacity(0.65), in: RoundedRectangle(cornerRadius: 12))
        .frame(height: height)
    }

    private func lyricChoice(_ option: ScrapeReviewOption?) -> ScrapeReviewLyrics? {
        if case .lyrics(let lyrics) = option?.value { return lyrics }
        return option == nil ? originalLyrics : nil
    }
}

private struct ScrapeReviewCoverImage: View {
    let cover: ScrapeReviewCover
    let images: ScrapeReviewImages
    @State private var image: CGImage?
    @State private var failed = false
    @State private var attempt = 0

    var body: some View {
        Group {
            if let image { Image(decorative: image, scale: 1).resizable().scaledToFit() }
            else if failed { Button("retry") { attempt += 1 } }
            else { ProgressView() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: attempt) {
            failed = false
            do { let result = try await images.thumbnail(for: cover); if !Task.isCancelled { image = result } }
            catch { if !Task.isCancelled { failed = true } }
        }
    }
}

private struct ScrapeReviewLyricLines: View {
    let lyrics: ScrapeReviewLyrics
    let expanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(verbatim: summary)
                if let format = lyrics.format { Text(verbatim: format) }
                if lyrics.lines.contains(where: { $0.manualTranslation != nil }) { Text("lyrics_translation_section") }
            }
            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(Array(lyrics.lines.prefix(expanded ? lyrics.lines.count : 4).enumerated()), id: \.offset) { _, line in
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
