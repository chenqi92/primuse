import AppIntents
import PrimuseKit
import SwiftUI
import WidgetKit

// MARK: - Timeline

struct SpokenWordShelfProvider: TimelineProvider {
    func placeholder(in context: Context) -> SpokenWordShelfEntry {
        SpokenWordShelfEntry(date: Date(), books: Self.demoBooks, includesProgress: true, playingBookID: nil)
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
            includesProgress: WidgetSettings.sharedDataScope().includesProgress,
            playingBookID: playingBookID()
        )
    }

    /// 正在听的那本书, 它的播放键换成暂停。关掉「正在播放」的数据同步时播放状态不外传, 也就不标。
    private static func playingBookID() -> String? {
        guard WidgetSettings.syncEnabled(),
              WidgetSettings.widgetEnabled(PrimuseConstants.widgetNowPlayingEnabledKey) else { return nil }
        return PlaybackState.load()?.playingSpokenWordBookID
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
    /// `SpokenWordBook.id` of the book playing right now.
    let playingBookID: String?
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

    /// 点播放键以外的地方打开 App 的有声书页, 方便换一本听。
    var body: some View {
        content.widgetURL(ListeningSpaceLink.url(for: .spokenWord))
    }

    @ViewBuilder private var content: some View {
        switch family {
        #if os(iOS)
        case .accessoryRectangular:
            if let book = entry.books.first {
                AccessorySpokenWordBook(book: book, includesProgress: entry.includesProgress,
                                        isPlaying: entry.playingBookID == book.id)
            } else {
                AccessorySpokenWordEmpty()
            }
        #endif
        case .systemMedium:
            if entry.books.count > 1 {
                MediumSpokenWordShelf(books: entry.books, includesProgress: entry.includesProgress,
                                      playingBookID: entry.playingBookID)
            } else if let book = entry.books.first {
                MediumSpokenWordBook(book: book, includesProgress: entry.includesProgress,
                                     isPlaying: entry.playingBookID == book.id)
            } else {
                SpokenWordShelfEmpty(isMedium: true)
            }
        default:
            if let book = entry.books.first {
                SmallSpokenWordBook(book: book, includesProgress: entry.includesProgress,
                                    isPlaying: entry.playingBookID == book.id)
            } else {
                SpokenWordShelfEmpty(isMedium: false)
            }
        }
    }
}

// MARK: - Home screen

/// 小号: 书封 + 书名作者 + 本书进度; 点播放键接着听 (在听的这本是暂停), 点别处打开有声书页。
private struct SmallSpokenWordBook: View {
    let book: SpokenWordShelfSnapshot.Book
    let includesProgress: Bool
    let isPlaying: Bool

    var body: some View {
        WidgetCanvas {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top) {
                    WidgetBookCover(coverImageName: book.coverImageName, width: 33)
                    Spacer()
                    SpokenWordPlayKey(book: book, isPlaying: isPlaying) {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(SpokenWordShelfText.tint)
                            .frame(width: 34, height: 34)
                            .background(SpokenWordShelfText.tint.opacity(0.10), in: .circle)
                    }
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
        .accessibilityElement(children: .contain)
    }
}

private struct MediumSpokenWordBook: View {
    let book: SpokenWordShelfSnapshot.Book
    let includesProgress: Bool
    let isPlaying: Bool

    var body: some View {
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
                            SpokenWordPlayKey(book: book, isPlaying: isPlaying) {
                                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(WidgetDesign.strongText)
                                    .frame(width: 30, height: 30)
                                    .background(SpokenWordShelfText.tint.opacity(0.22), in: .circle)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .widgetBounds(geometry.size)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

/// 中号、在听的不止一本: 最多三本并排, 每本书封角上一个播放键。
///
/// 书封由高度定宽(方形), 比平分出来的一列窄; 以前每本靠列的左边放, 最后一本右边空出
/// 一大块。现在从小组件的边缘量起, 书封之间、书封和两边留一样宽的空, 进度条和书封一样宽、
/// 对齐在书封下面, 书名在下面居中, 可以比书封宽(占到两本之间的空), 最多两行。
private struct MediumSpokenWordShelf: View {
    let books: [SpokenWordShelfSnapshot.Book]
    let includesProgress: Bool
    let playingBookID: String?
    @Environment(\.widgetRenderingMode) private var renderingMode
    /// The canvas padding; the even gaps are measured from the widget's edges.
    private let inset: CGFloat = 14

    var body: some View {
        WidgetCanvas(padding: inset) {
            GeometryReader { geometry in
                let shown = Array(books.prefix(SpokenWordWidgetPolicy.shelfLimit))
                let columns = CGFloat(max(1, shown.count))
                let eyebrowHeight: CGFloat = 16
                // Progress bar, two lines of title (CJK fonts run taller) and the spacing between them.
                let textHeight: CGFloat = 42
                let evenColumnWidth: CGFloat = (geometry.size.width - 12 * (columns - 1)) / columns
                // 标题下面至少留 8,再和底下平分余下的高度(#283:书封整块往下挪,上下匀称)。
                let titleGap: CGFloat = 8
                let heightLeft: CGFloat = geometry.size.height - eyebrowHeight - textHeight - titleGap
                let coverHeight: CGFloat = max(40, min(
                    SpokenWordCoverLayout.height(forWidth: evenColumnWidth * 0.62), heightLeft
                ))
                let coverWidth: CGFloat = SpokenWordCoverLayout.width(forHeight: coverHeight)
                // The same gap before, between and after the covers, counted from the widget's edges.
                let widgetWidth: CGFloat = geometry.size.width + inset * 2
                let gap: CGFloat = max(8, (widgetWidth - coverWidth * columns) / (columns + 1))
                // A title may spread into the gaps beside its cover, short of touching the next title.
                let titleExtra: CGFloat = max(0, min(gap - 8, 2 * (gap - inset)))
                VStack(alignment: .leading, spacing: 0) {
                    SpokenWordShelfEyebrow()
                        .frame(height: eyebrowHeight)
                    Spacer(minLength: titleGap)
                    HStack(alignment: .top, spacing: gap - titleExtra) {
                        ForEach(shown) { book in
                            let isPlaying = playingBookID == book.id
                            VStack(spacing: 4) {
                                WidgetBookCover(
                                    coverImageName: book.coverImageName,
                                    width: coverWidth,
                                    cornerRadius: 6
                                )
                                .overlay(alignment: .bottomTrailing) {
                                    SpokenWordPlayKey(book: book, isPlaying: isPlaying) {
                                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                                            .font(.system(size: 10, weight: .bold))
                                            .foregroundStyle(SpokenWordShelfText.tint)
                                            .frame(width: 24, height: 24)
                                            .background(playKeyBackdrop, in: .circle)
                                            .overlay { Circle().strokeBorder(SpokenWordShelfText.tint.opacity(0.18), lineWidth: 1) }
                                    }
                                    .padding(4)
                                }
                                if includesProgress {
                                    ProgressView(value: min(1, max(0, book.fractionComplete)))
                                        .progressViewStyle(WidgetHairlineBar())
                                        .frame(width: coverWidth)
                                }
                                Text(book.title)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(WidgetDesign.strongText)
                                    .multilineTextAlignment(.center)
                                    .lineLimit(2)
                                    .frame(width: coverWidth + titleExtra)
                            }
                            .frame(width: coverWidth + titleExtra)
                            .accessibilityElement(children: .contain)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    Spacer(minLength: 0)
                }
                .widgetBounds(geometry.size)
            }
        }
    }

    /// 书封角上播放键垫的底色。色调、透明外观下它会被渲染成一块实心白片(#190),只在全彩时画。
    private var playKeyBackdrop: AnyShapeStyle {
        renderingMode == .fullColor ? AnyShapeStyle(.background) : AnyShapeStyle(Color.clear)
    }
}

private struct SpokenWordShelfEmpty: View {
    let isMedium: Bool
    var body: some View {
        WidgetEmptyState(symbol: ListeningSpace.spokenWord.systemImage,
                         title: PMString("ext.widget.spokenWordShelf.empty.title"),
                         subtitle: PMString("ext.widget.spokenWordShelf.empty.subtitle"),
                         tint: SpokenWordShelfText.tint)
    }
}

// MARK: - Lock screen

#if os(iOS)
private struct AccessorySpokenWordBook: View {
    let book: SpokenWordShelfSnapshot.Book
    let includesProgress: Bool
    let isPlaying: Bool

    /// 锁屏上整块是播放键: 在听的这本点了是暂停, 书名前的图标跟着换成暂停。
    var body: some View {
        Button(intent: PrimuseResumeSpokenWordBookIntent(bookID: book.id)) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Image(systemName: isPlaying ? "pause.fill" : ListeningSpace.spokenWord.systemImage)
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
                Image(systemName: ListeningSpace.spokenWord.systemImage)
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
            Image(systemName: ListeningSpace.spokenWord.systemImage)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(SpokenWordShelfText.tint)
                .widgetAccentable()
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

/// 书的播放键: 点了从上次停下的地方接着听, 在听的这本是暂停。只有它是按钮, 别处点了按
/// `widgetURL` 打开 App 的有声书页; 关掉小组件交互时不做按钮, 整块都是打开 App。
private struct SpokenWordPlayKey<Content: View>: View {
    let book: SpokenWordShelfSnapshot.Book
    let isPlaying: Bool
    @ViewBuilder let label: () -> Content

    var body: some View {
        if WidgetSettings.clickableInteractionEnabled() {
            Button(intent: PrimuseResumeSpokenWordBookIntent(bookID: book.id)) {
                label().contentShape(.circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(PMString(isPlaying ? "ext.control.pause" : "ext.control.play") + ", "
                                + SpokenWordShelfText.accessibilityLabel(book))
        } else {
            label().accessibilityHidden(true)
        }
    }
}

private enum SpokenWordShelfText {
    /// 有声书这一类的颜色, 和 App 首页顶部切换、资料库同一份。
    static var tint: Color { WidgetDesign.tint(for: .spokenWord) }

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
                    .fill(SpokenWordShelfText.tint)
                    .frame(width: geometry.size.width * fraction)
            }
        }
        .frame(height: 2.5)
    }
}

/// Preserve the entire book cover inside its square frame.
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
