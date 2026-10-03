import SwiftUI
import PrimuseKit

// MARK: - Style

/// 有声书竖版播放页的两套设计,跟着明暗外观走:
/// 深色是「墨黑」,章号一栏在封面左侧、书名压在最上面;
/// 浅色是「暖白」,像书刊的版式,封面在左、章号在右、书名排在封面下方。
/// 两套都是纯色底,不随封面取色。播客单集不用这套。
struct AudiobookPlayerStyle: Equatable {
    enum Variant: Equatable {
        case nocturne
        case paper
    }

    let variant: Variant
    let usesIncreasedContrast: Bool

    init(colorScheme: ColorScheme, contrast: ColorSchemeContrast) {
        variant = colorScheme == .dark ? .nocturne : .paper
        usesIncreasedContrast = contrast == .increased
    }

    var isNocturne: Bool { variant == .nocturne }

    var background: Color {
        isNocturne
            ? Color(red: 0.071, green: 0.071, blue: 0.075)
            : Color(red: 0.969, green: 0.953, blue: 0.925)
    }

    var primary: Color {
        isNocturne
            ? .white.opacity(usesIncreasedContrast ? 1 : 0.94)
            : ink.opacity(usesIncreasedContrast ? 1 : 0.94)
    }

    var secondary: Color {
        foreground.opacity(usesIncreasedContrast ? 0.80 : (isNocturne ? 0.62 : 0.66))
    }

    var tertiary: Color {
        foreground.opacity(usesIncreasedContrast ? 0.68 : (isNocturne ? 0.46 : 0.50))
    }

    var faint: Color {
        foreground.opacity(usesIncreasedContrast ? 0.56 : (isNocturne ? 0.32 : 0.38))
    }

    var hairline: Color {
        foreground.opacity(usesIncreasedContrast ? 0.26 : (isNocturne ? 0.14 : 0.13))
    }

    /// 进度条未播的那一段。
    var track: Color {
        foreground.opacity(usesIncreasedContrast ? 0.32 : (isNocturne ? 0.18 : 0.14))
    }

    /// 进度条已播的一段、拖动点与播放键的底色:墨黑是橙红,暖白是近黑。
    var accent: Color {
        isNocturne
            ? Color(red: 0.91, green: 0.42, blue: 0.31)
            : Color(red: 0.11, green: 0.13, blue: 0.13)
    }

    /// 播放键里的三角,取底色,像在实心圆上挖出来的。
    var onAccent: Color { background }

    /// 章号下那条竖线上的全书进度点。暖白里用深红,不跟近黑的进度条抢。
    var bookMarker: Color {
        isNocturne ? accent : Color(red: 0.62, green: 0.17, blue: 0.14)
    }

    /// 给通用有声零件(语速、定时、书签、目录那一排)用的配色。
    var palette: SpokenWordPlayerPalette {
        SpokenWordPlayerPalette(
            primary: primary,
            secondary: secondary,
            tertiary: tertiary,
            accent: accent,
            tileFill: foreground.opacity(isNocturne ? 0.10 : 0.06)
        )
    }

    private var ink: Color { Color(red: 0.11, green: 0.106, blue: 0.10) }
    private var foreground: Color { isNocturne ? .white : ink }
}

// MARK: - Chrome

/// 字距放开的小标签:「CHAPTER」「当前章节」「正在收听」。
struct AudiobookPlayerEyebrow: View {
    let key: LocalizedStringKey
    let style: AudiobookPlayerStyle

    var body: some View {
        Text(key)
            .font(.system(size: 10, weight: .medium))
            .tracking(style.isNocturne ? 2 : 1.2)
            .textCase(style.isNocturne ? Text.Case.uppercase : nil)
            .foregroundStyle(style.tertiary)
            .lineLimit(1)
    }
}

// MARK: - Hero row

/// 封面与章号并排的那一行。章号一栏定宽,封面是正方形,边长取「余下的宽」与「这一行分到的高」
/// 里小的那个 —— 竖向排布里只有它会让,屏幕矮时封面变小,文字与控件不被挤掉。
/// 子视图按「章号栏、封面」的顺序给。
struct AudiobookHeroRowLayout: Layout {
    var columnLeading: Bool
    var columnWidth: CGFloat
    var spacing: CGFloat
    var maxSide: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? (columnWidth + spacing + maxSide)
        return CGSize(width: width, height: coverSide(width: width, height: proposal.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let side = coverSide(width: bounds.width, height: bounds.height)
        let columnX = columnLeading ? bounds.minX : bounds.minX + side + spacing
        let coverX = columnLeading ? bounds.maxX - side : bounds.minX
        subviews[0].place(
            at: CGPoint(x: columnX, y: bounds.minY),
            anchor: .topLeading,
            proposal: ProposedViewSize(width: columnWidth, height: side)
        )
        subviews[1].place(
            at: CGPoint(x: coverX, y: bounds.minY),
            anchor: .topLeading,
            proposal: ProposedViewSize(width: side, height: side)
        )
    }

    private func coverSide(width: CGFloat, height: CGFloat?) -> CGFloat {
        let byWidth = width - columnWidth - spacing
        let side = min(maxSide, byWidth, height ?? .infinity)
        guard side.isFinite else { return 0 }
        return max(0, side.rounded(.down))
    }
}

// MARK: - Chapter column

/// 章号那一栏:「CHAPTER / 35 / ⁄ 1023」,下面一条短竖线上的点是全书听到哪儿,再下面「全书 3%」。
/// 一个文件又没有章节标记的书没有章号,大数字换成全书百分比。点开是目录。
/// 自己一个视图,读的是存下的位置而不是播放头(同 `SpokenWordPartPositionButton`),几秒才重画一次。
struct AudiobookChapterColumn: View {
    let style: AudiobookPlayerStyle
    let action: () -> Void
    @Environment(AudioPlayerService.self) private var player

    var body: some View {
        let store = SpokenWordStore.shared
        // Registers the column with the store, so the stored positions it
        // reads redraw it when they change.
        let _ = store.positions.count
        let _ = store.finishedAt.count
        let summary = player.spokenWordNowPlayingSummary(live: false) ?? SpokenWordNowPlayingSummary()
        let fraction = min(1, max(0, summary.bookFraction))
        let percent = Int((fraction * 100).rounded(.down))
        let hasParts = summary.partIndex != nil && summary.partCount != nil

        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                AudiobookPlayerEyebrow(key: eyebrowKey(hasParts: hasParts), style: style)

                Text(verbatim: hasParts ? "\(summary.partIndex ?? 0)" : "\(percent)")
                    .font(numberFont)
                    .foregroundStyle(style.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.4)
                    .padding(.top, style.isNocturne ? 4 : 2)
                    .contentTransition(.numericText())

                Text(verbatim: hasParts ? "/ \(summary.partCount ?? 0)" : "%")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(style.tertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                AudiobookBookProgressLine(
                    fraction: fraction,
                    track: style.hairline,
                    marker: style.bookMarker
                )
                .frame(width: 5, height: 40)
                .padding(.top, style.isNocturne ? 26 : 20)

                Group {
                    if hasParts {
                        Text(verbatim: SpokenWordPlayerText.bookFraction(fraction))
                    } else if let remaining = SpokenWordPlayerText.bookRemaining(summary, rate: player.currentSpokenWordRate) {
                        Text(verbatim: remaining)
                    }
                }
                .font(.caption2)
                .foregroundStyle(style.tertiary)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .padding(.top, 10)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, style.isNocturne ? 10 : 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pmAnimation(.control, value: summary.partIndex)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("spoken_word_contents_title"))
        .accessibilityValue(Text(verbatim: accessibilityValue(summary)))
    }

    /// 墨黑写「CHAPTER」,暖白写「当前章节」;没有章号的书两套都写「全书进度」。
    private func eyebrowKey(hasParts: Bool) -> LocalizedStringKey {
        guard hasParts else { return "spoken_word_player_progress_eyebrow" }
        return style.isNocturne ? "spoken_word_player_chapter_eyebrow" : "spoken_word_player_current_part"
    }

    private var numberFont: Font {
        style.isNocturne
            ? Font.system(size: 64, weight: .thin)
            : Font.system(size: 64, weight: .regular, design: .serif)
    }

    private func accessibilityValue(_ summary: SpokenWordNowPlayingSummary) -> String {
        if let position = SpokenWordPlayerText.partPosition(summary) {
            return SpokenWordPlayerText.partPositionWithBook(position, summary: summary, rate: player.currentSpokenWordRate)
        }
        return [
            SpokenWordPlayerText.bookFraction(summary.bookFraction),
            SpokenWordPlayerText.bookRemaining(summary, rate: player.currentSpokenWordRate),
        ]
        .compactMap { $0 }
        .joined(separator: ", ")
    }
}

/// 一条短竖线,点从上往下走到全书听到的位置,走过的一段淡淡地染上点的颜色。
struct AudiobookBookProgressLine: View {
    let fraction: Double
    let track: Color
    let marker: Color

    var body: some View {
        GeometryReader { proxy in
            let clamped = CGFloat(min(1, max(0, fraction)))
            let dot: CGFloat = 5
            let travel = max(0, proxy.size.height - dot)
            ZStack(alignment: .top) {
                Rectangle()
                    .fill(track)
                    .frame(width: 1)
                Rectangle()
                    .fill(marker.opacity(0.5))
                    .frame(width: 1, height: travel * clamped + dot / 2)
                Circle()
                    .fill(marker)
                    .frame(width: dot, height: dot)
                    .offset(y: travel * clamped)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Title

/// 书名、作者、演播。点开是这本书。墨黑用粗黑体;暖白用细的衬线体、字距放开。
struct AudiobookTitleBlock: View {
    let style: AudiobookPlayerStyle
    let onOpenBook: () -> Void
    @Environment(AudioPlayerService.self) private var player
    @ScaledMetric(relativeTo: .title) private var titleSize: CGFloat = 30

    var body: some View {
        let title = SpokenWordPlayerText.bookTitle(player)
        let author = SpokenWordPlayerText.author(player)
        let narrator = SpokenWordPlayerText.narrator(player)
        Button(action: onOpenBook) {
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: title)
                    .font(style.isNocturne
                        ? Font.system(size: titleSize, weight: .bold)
                        : Font.system(size: titleSize, weight: .light, design: .serif))
                    .tracking(titleTracking(for: title))
                    .foregroundStyle(style.primary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .fixedSize(horizontal: false, vertical: true)

                if let author {
                    Text(verbatim: author)
                        .font(.subheadline)
                        .foregroundStyle(style.secondary)
                        .lineLimit(1)
                        .padding(.top, style.isNocturne ? 10 : 12)
                }
                if let narrator {
                    Text(verbatim: narrator)
                        .font(.footnote)
                        .foregroundStyle(style.tertiary)
                        .lineLimit(1)
                        .padding(.top, 6)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contentTransition(.opacity)
        .pmAnimation(.trackChange, value: player.currentSong?.id)
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text("spoken_word_go_to_book"))
    }

    /// 暖白的书名字距放开,中日韩文字放得多一些,西文只放一点,免得像拆开的单词。
    private func titleTracking(for title: String) -> CGFloat {
        guard !style.isNocturne else { return 0 }
        let isHan = title.unicodeScalars.contains { scalar in
            (0x3040...0x30FF).contains(scalar.value)
                || (0x3400...0x9FFF).contains(scalar.value)
                || (0xAC00...0xD7AF).contains(scalar.value)
        }
        return isHan ? titleSize * 0.12 : titleSize * 0.02
    }
}

// MARK: - Current part

/// 正在听的这一章:「36 | 【神作｜宿环】」,文件名开头的集数单独排出来;右边是上一章 / 下一章。
/// 点标题打开目录。
struct AudiobookCurrentPartRow: View {
    let style: AudiobookPlayerStyle
    let onOpenContents: () -> Void
    @Environment(AudioPlayerService.self) private var player

    var body: some View {
        let label = SpokenWordPartTitleLabel(
            SpokenWordPlayerText.partTitle(player) ?? player.currentSong?.title ?? ""
        )
        VStack(alignment: .leading, spacing: 6) {
            if style.isNocturne {
                AudiobookPlayerEyebrow(key: "spoken_word_player_current_part", style: style)
            }
            HStack(spacing: 0) {
                Button(action: onOpenContents) {
                    HStack(spacing: 10) {
                        if let number = label.number {
                            Text(verbatim: number)
                                .font(.body.weight(.semibold).monospacedDigit())
                                .fixedSize()
                            Rectangle()
                                .fill(style.tertiary)
                                .frame(width: 1, height: 14)
                                .accessibilityHidden(true)
                        }
                        Text(verbatim: label.title)
                            .font(.body.weight(style.isNocturne ? .medium : .regular))
                            .lineLimit(1)
                    }
                    .foregroundStyle(style.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityHint(Text("spoken_word_contents_title"))

                SpokenWordPartButton(forward: false, color: style.primary, font: .callout)
                SpokenWordPartButton(forward: true, color: style.primary, font: .callout)
                    // 图标贴着右边距,点按范围仍是整块 44pt。
                    .padding(.trailing, -13)
            }
        }
        .contentTransition(.opacity)
        .pmAnimation(.trackChange, value: label)
    }
}

// MARK: - Progress

/// 本章的细进度条与时间。和播放页其它地方一样单独成一个视图,播放时钟只让这一块重画。
struct AudiobookProgressBar: View {
    let style: AudiobookPlayerStyle
    @Environment(AudioPlayerService.self) private var player
    @State private var previewTime: TimeInterval?

    var body: some View {
        let displayedTime = previewTime ?? player.currentTime
        VStack(spacing: 0) {
            ProgressSlider(
                value: player.currentTime,
                total: player.duration,
                interactionID: player.currentSong?.id,
                fillTint: style.accent,
                trackStyle: ProgressSlider.TrackStyle(
                    restingHeight: 2,
                    draggingHeight: 4,
                    trackColor: style.track,
                    knobDiameter: 9
                ),
                onPreview: { previewTime = $0 },
                onSeek: { player.seek(to: $0) }
            )
            .overlay {
                SpokenWordBookmarkTicks(color: style.primary.opacity(0.7))
            }

            HStack {
                Text(verbatim: displayedTime.formattedDuration)
                    .contentTransition(.numericText())
                Spacer(minLength: 8)
                Text(verbatim: "-\(max(0, player.duration - displayedTime).formattedDuration)")
                    .contentTransition(.numericText())
            }
            .overlay {
                // 按这本书的语速折算,不是内容时长。拖动时让位给跟手的时间。
                if previewTime == nil, let remaining = SpokenWordPlayerText.partRemaining(player) {
                    Text(verbatim: remaining)
                        .font(.caption2)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .padding(.horizontal, 64)
                }
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(style.tertiary)
            .padding(.top, -8)
        }
    }
}
