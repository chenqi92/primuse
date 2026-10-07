import AppIntents
import PrimuseKit
import SwiftUI
import WidgetKit

// MARK: - Timeline

struct SpokenWordShelfProvider: TimelineProvider {
    func placeholder(in context: Context) -> SpokenWordShelfEntry {
        SpokenWordShelfEntry(date: Date(), books: Self.demoBooks, includesProgress: true)
    }

    func getSnapshot(in context: Context, completion: @escaping (SpokenWordShelfEntry) -> Void) {
        // 画廊预览喂示例书, 真实使用走 App Group。同 NowPlayingProvider。
        if context.isPreview {
            completion(placeholder(in: context))
        } else {
            completion(Self.currentEntry())
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SpokenWordShelfEntry>) -> Void) {
        // 书的进度只在听的时候变, 由主 app 写快照后按需 reload;
        // 这里的定时刷新只是兜底。
        let policy = WidgetSettings.nextRefreshDate().map { TimelineReloadPolicy.after($0) } ?? .never
        completion(Timeline(entries: [Self.currentEntry()], policy: policy))
    }

    private static func currentEntry() -> SpokenWordShelfEntry {
        let snapshot = WidgetSettings.syncEnabled() ? SpokenWordShelfSnapshot.load() : nil
        return SpokenWordShelfEntry(
            date: Date(),
            books: snapshot?.books ?? [],
            includesProgress: WidgetSettings.sharedDataScope().includesProgress
        )
    }

    private static let demoBooks: [SpokenWordShelfSnapshot.Book] = [
        .init(id: "demo-1", title: "Pride and Prejudice", author: "Jane Austen",
              fractionComplete: 0.38, remaining: 6.5 * 3600, partIndex: 12, partCount: 61),
        .init(id: "demo-2", title: "The Odyssey", author: "Homer",
              fractionComplete: 0.72, remaining: 3.2 * 3600, partIndex: 18, partCount: 24),
        .init(id: "demo-3", title: "Walden", author: "Henry David Thoreau",
              fractionComplete: 0.12, remaining: 9 * 3600, partIndex: 2, partCount: 18),
    ]
}

struct SpokenWordShelfEntry: TimelineEntry {
    let date: Date
    let books: [SpokenWordShelfSnapshot.Book]
    let includesProgress: Bool
}

struct SpokenWordShelfWidget: Widget {
    /// Same string as `SpokenWordWidgetPublisher.widgetKind` in the app.
    let kind = "SpokenWordShelfWidget"

    private var families: [WidgetFamily] {
        #if os(iOS)
        [.systemSmall, .systemMedium, .accessoryRectangular]
        #else
        [.systemSmall, .systemMedium]
        #endif
    }

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: SpokenWordShelfProvider()) { entry in
            SpokenWordShelfWidgetView(entry: entry)
        }
        .contentMarginsDisabled()
        .configurationDisplayName(PMString("ext.widget.spokenWordShelf.displayName"))
        .description(PMString("ext.widget.spokenWordShelf.description"))
        .supportedFamilies(families)
    }
}

struct SpokenWordShelfWidgetView: View {
    let entry: SpokenWordShelfEntry

    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        #if os(iOS)
        case .accessoryRectangular:
            if let book = entry.books.first {
                AccessorySpokenWordBook(book: book, includesProgress: entry.includesProgress)
            } else {
                AccessorySpokenWordEmpty()
            }
        #endif
        case .systemMedium:
            if entry.books.count > 1 {
                MediumSpokenWordShelf(books: entry.books, includesProgress: entry.includesProgress)
            } else if let book = entry.books.first {
                MediumSpokenWordBook(book: book, includesProgress: entry.includesProgress)
            } else {
                SpokenWordShelfEmpty(isMedium: true)
            }
        default:
            if let book = entry.books.first {
                SmallSpokenWordBook(book: book, includesProgress: entry.includesProgress)
            } else {
                SpokenWordShelfEmpty(isMedium: false)
            }
        }
    }
}

// MARK: - Home screen

/// 小号: 书封 + 书名作者 + 本书进度, 点整块接着听。
private struct SmallSpokenWordBook: View {
    let book: SpokenWordShelfSnapshot.Book
    let includesProgress: Bool

    var body: some View {
        Button(intent: PrimuseResumeSpokenWordBookIntent(bookID: book.id)) {
            WidgetCanvas {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top) {
                        WidgetBookCover(coverImageName: book.coverImageName, width: 33)
                        Spacer()
                        Image(systemName: "play.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(WidgetDesign.brandTint)
                            .frame(width: 34, height: 34)
                            .background(WidgetDesign.brandTint.opacity(0.10), in: .circle)
                    }
                    Spacer(minLength: 0)
                    Text(book.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(WidgetDesign.strongText)
                        .lineLimit(2)
                    if let author = book.author, !author.isEmpty {
                        Text(author).font(.system(size: 12))
                            .foregroundStyle(WidgetDesign.secondaryText).lineLimit(1)
                    }
                    if includesProgress {
                        ProgressView(value: min(1, max(0, book.fractionComplete)))
                            .progressViewStyle(WidgetHairlineBar())
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(SpokenWordShelfText.accessibilityLabel(book))
    }
}

private struct MediumSpokenWordBook: View {
    let book: SpokenWordShelfSnapshot.Book
    let includesProgress: Bool

    var body: some View {
        Button(intent: PrimuseResumeSpokenWordBookIntent(bookID: book.id)) {
            WidgetCanvas(padding: 16) {
                GeometryReader { geometry in
                    let coverHeight = max(80, geometry.size.height)
                    HStack(alignment: .top, spacing: 14) {
                        WidgetBookCover(
                            coverImageName: book.coverImageName,
                            width: SpokenWordCoverLayout.width(forHeight: coverHeight),
                            cornerRadius: 8
                        )
                        VStack(alignment: .leading, spacing: 4) {
                            SpokenWordShelfEyebrow()
                            Text(book.title)
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(WidgetDesign.strongText)
                                .lineLimit(2)
                                .minimumScaleFactor(0.86)
                            if let author = book.author {
                                Text(author)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(WidgetDesign.secondaryText)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            HStack(alignment: .bottom, spacing: 10) {
                                SpokenWordBookProgressFooter(book: book, includesProgress: includesProgress, compact: false)
                                Image(systemName: "play.fill")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(WidgetDesign.strongText)
                                    .frame(width: 30, height: 30)
                                    .background(WidgetDesign.brandTint.opacity(0.22), in: .circle)
                                    .accessibilityHidden(true)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .widgetBounds(geometry.size)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(SpokenWordShelfText.accessibilityLabel(book))
    }
}

/// 中号、在听的不止一本: 最多三本并排, 每本单独一个点按区。
private struct MediumSpokenWordShelf: View {
    let books: [SpokenWordShelfSnapshot.Book]
    let includesProgress: Bool

    var body: some View {
        WidgetCanvas(padding: 14) {
            GeometryReader { geometry in
                let shown = Array(books.prefix(SpokenWordWidgetPolicy.shelfLimit))
                let spacing: CGFloat = 12
                let eyebrowHeight: CGFloat = 16
                let columns = max(1, shown.count)
                let columnWidth = (geometry.size.width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
                let textHeight: CGFloat = 30
                let coverHeight = max(40, min(
                    SpokenWordCoverLayout.height(forWidth: columnWidth * 0.62),
                    geometry.size.height - eyebrowHeight - textHeight - 8
                ))
                VStack(alignment: .leading, spacing: 4) {
                    SpokenWordShelfEyebrow()
                        .frame(height: eyebrowHeight)
                    HStack(alignment: .top, spacing: spacing) {
                        ForEach(shown) { book in
                            Button(intent: PrimuseResumeSpokenWordBookIntent(bookID: book.id)) {
                                VStack(alignment: .leading, spacing: 4) {
                                    WidgetBookCover(
                                        coverImageName: book.coverImageName,
                                        width: SpokenWordCoverLayout.width(forHeight: coverHeight),
                                        cornerRadius: 6
                                    )
                                    Text(book.title)
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(WidgetDesign.strongText)
                                        .lineLimit(1)
                                    if includesProgress {
                                        ProgressView(value: min(1, max(0, book.fractionComplete)))
                                            .progressViewStyle(WidgetHairlineBar())
                                    }
                                }
                                .frame(width: columnWidth, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(SpokenWordShelfText.accessibilityLabel(book))
                        }
                    }
                }
                .widgetBounds(geometry.size)
            }
        }
    }
}

private struct SpokenWordShelfEmpty: View {
    let isMedium: Bool
    var body: some View {
        WidgetEmptyState(symbol: "books.vertical", title: PMString("ext.widget.spokenWordShelf.empty.title"),
                         subtitle: PMString("ext.widget.spokenWordShelf.empty.subtitle"))
    }
}

// MARK: - Lock screen

#if os(iOS)
private struct AccessorySpokenWordBook: View {
    let book: SpokenWordShelfSnapshot.Book
    let includesProgress: Bool

    var body: some View {
        Button(intent: PrimuseResumeSpokenWordBookIntent(bookID: book.id)) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Image(systemName: "book.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .widgetAccentable()
                    Text(book.title)
                        .font(.headline)
                        .lineLimit(1)
                }
                if let detail = SpokenWordShelfText.detail(book, includesProgress: includesProgress) {
                    Text(detail)
                        .font(.caption2)
                        .lineLimit(1)
                }
                if includesProgress {
                    ProgressView(value: min(1, max(0, book.fractionComplete)))
                        .progressViewStyle(.linear)
                        .widgetAccentable()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .containerBackground(for: .widget) { Color.clear }
    }
}

private struct AccessorySpokenWordEmpty: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Image(systemName: "books.vertical.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .widgetAccentable()
                Text(PMString("ext.widget.spokenWordShelf.eyebrow"))
                    .font(.headline)
            }
            Text(PMString("ext.widget.spokenWordShelf.empty.title"))
                .font(.caption2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .containerBackground(for: .widget) { Color.clear }
    }
}
#endif

// MARK: - Parts

private struct SpokenWordShelfEyebrow: View {
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "book.fill")
                .font(.system(size: 9, weight: .bold))
            Text(verbatim: PMString("ext.widget.spokenWordShelf.eyebrow"))
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(WidgetDesign.tertiaryText)
    }
}

/// 进度条 + 「第 12/61 章 · 剩 6 小时」。
private struct SpokenWordBookProgressFooter: View {
    let book: SpokenWordShelfSnapshot.Book
    let includesProgress: Bool
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if includesProgress {
                ProgressView(value: min(1, max(0, book.fractionComplete)))
                    .progressViewStyle(WidgetHairlineBar())
            }
            if let detail = SpokenWordShelfText.detail(book, includesProgress: includesProgress) {
                Text(verbatim: detail)
                    .font(.system(size: compact ? 9.5 : 10.5, weight: .medium))
                    .foregroundStyle(WidgetDesign.tertiaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private enum SpokenWordShelfText {
    static func detail(_ book: SpokenWordShelfSnapshot.Book, includesProgress: Bool) -> String? {
        var parts: [String] = []
        if let index = book.partIndex, book.partCount > 1 {
            parts.append(PMString("ext.widget.spokenWord.partFormat", index, book.partCount))
        }
        if includesProgress, let remaining = spokenWordRemainingText(book.remaining) {
            parts.append(remaining)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func accessibilityLabel(_ book: SpokenWordShelfSnapshot.Book) -> String {
        [PMString("ext.widget.spokenWordShelf.eyebrow"), book.title, book.author]
            .compactMap { $0 }
            .joined(separator: ", ")
    }
}

/// 2.5pt 细进度条, 与正在播放小组件同一视觉重量。
private struct WidgetHairlineBar: ProgressViewStyle {
    func makeBody(configuration: Configuration) -> some View {
        GeometryReader { geometry in
            let fraction = CGFloat(max(0, min(1, configuration.fractionCompleted ?? 0)))
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                Capsule()
                    .fill(WidgetDesign.brandTint)
                    .frame(width: geometry.size.width * fraction)
            }
        }
        .frame(height: 2.5)
    }
}

/// Preserve the entire book cover inside its portrait frame.
struct WidgetBookCover: View {
    let coverImageName: String?
    let width: CGFloat
    var cornerRadius: CGFloat = 6
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        let height = SpokenWordCoverLayout.height(forWidth: width)
        ZStack {
            if let image = loadImage() {
                Color.primary.opacity(0.04)
                Image(widgetImage: image)
                    .resizable()
                    .widgetAccentedRenderingMode(.fullColor)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: width, height: height)
            } else {
                WidgetPlaceholderArtwork(systemName: "book.closed", cornerRadius: cornerRadius)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
    }

    private func loadImage() -> WidgetImage? {
        guard let coverImageName, !coverImageName.isEmpty,
              let containerURL = FileManager.default.containerURL(
                  forSecurityApplicationGroupIdentifier: PrimuseConstants.appGroupIdentifier
              ),
              let data = try? Data(contentsOf: containerURL.appendingPathComponent(coverImageName)) else {
            return nil
        }
        return WidgetImage(data: data)
    }
}
