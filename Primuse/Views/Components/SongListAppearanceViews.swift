import SwiftUI
import PrimuseKit

/// 曲库「歌曲」页的三种外观：列表、时间线、封面。后两种照最初的设计稿：
/// 时间线是中轴两侧交替的玻璃卡片，封面是左右交替、带透视的大封面压一块玻璃胶囊。
/// 中间几天存下过的 `tiles`（方块）、`focus`（聚焦）读到后换成最接近的封面、时间线。
enum SongListAppearance: String, CaseIterable {
    case list, timeline, artwork

    static let storageKey = "songListAppearance"

    static func resolved(_ value: String) -> Self {
        switch value {
        case "tiles": .artwork
        case "focus": .timeline
        default: Self(rawValue: value) ?? .list
        }
    }

    var titleKey: LocalizedStringKey {
        switch self {
        case .list: "song_list_layout_list"
        case .timeline: "song_list_layout_timeline"
        case .artwork: "song_list_layout_artwork"
        }
    }

    var symbol: String {
        switch self {
        case .list: "list.bullet"
        case .timeline: "timeline.selection"
        case .artwork: "photo.on.rectangle.angled"
        }
    }

    /// 时间线与封面共用的版式；列表为 nil。
    var timelineStyle: SongTimelineGeometry.Style? {
        switch self {
        case .list: nil
        case .timeline: .timeline
        case .artwork: .artwork
        }
    }
}

extension EnvironmentValues {
    @Entry var songListAppearance: SongListAppearance = .list
    /// 时间线 / 封面外观里一行拿到的宽度，由外层 `SongTimelineStack` 量一次经环境传下来。
    /// 为 0（还没量出来，或者行不在栈里）时按 `SongTimelineGeometry.fallbackWidth` 排。
    @Entry var songTimelineWidth: CGFloat = 0
}

struct SongListAppearancePreference: ViewModifier {
    @AppStorage(SongListAppearance.storageKey) private var storedAppearance = SongListAppearance.list.rawValue

    func body(content: Content) -> some View {
        content.environment(\.songListAppearance, SongListAppearance.resolved(storedAppearance))
    }
}

/// 歌曲页「⋯」菜单里的一行，点开是三种外观的单选。
/// 工具栏条目跑在自己的视图图里，这里只读 `@AppStorage`，不读环境。
struct SongListAppearancePicker: View {
    @AppStorage(SongListAppearance.storageKey) private var storedAppearance = SongListAppearance.list.rawValue

    var body: some View {
        let current = SongListAppearance.resolved(storedAppearance)
        Picker(selection: Binding(
            get: { SongListAppearance.resolved(storedAppearance) },
            set: { storedAppearance = $0.rawValue }
        )) {
            ForEach(SongListAppearance.allCases, id: \.self) { appearance in
                Label(appearance.titleKey, systemImage: appearance.symbol)
                    .tag(appearance)
            }
        } label: {
            Label("song_list_layout", systemImage: current.symbol)
        }
        .pickerStyle(.menu)
        .accessibilityIdentifier("songList.appearance")
    }
}

extension View {
    /// 行的点按、长按范围。列表整行都算；时间线与封面外观由行内容自己给出命中形状
    /// （卡片或胶囊、封面、节点那一段），中轴另一侧空着的半行不截走邻居伸过来的大封面上的点按与长按。
    @ViewBuilder
    func songListRowHitRegion(_ appearance: SongListAppearance) -> some View {
        if appearance == .list {
            contentShape(Rectangle())
        } else {
            self
        }
    }
}

// MARK: - 时间线与封面共用

enum SongTimelineRowMetrics {
    /// 时间线卡片的基础高度（随动态字号放大）。
    static let timelineCardHeight: CGFloat = 64
    /// 封面外观玻璃胶囊的基础高度（随动态字号放大）。
    static let artworkCapsuleHeight: CGFloat = 58
    /// 栈首尾在「内容伸出槽位」之外再多留的距离。
    static let stackVerticalPadding: CGFloat = 10
    /// 时间线外观的左右留白。封面外观贴边，让大封面伸出屏幕。
    static let timelineHorizontalInset: CGFloat = 14
}

/// 时间线 / 封面外观的懒加载栈。每首歌仍是 `ForEach` 里的一个子视图、带着调用方给的身份，
/// 一个位置一个滚动目标，定位直接按身份跳过去；行宽在这里量一次，经环境传给每一行。
///
/// 中轴是栈背后的一条细线：一整条，不随单行的按压、淡入淡出断开，也省得每行各画一段。
struct SongTimelineStack<Content: View>: View {
    let appearance: SongListAppearance
    /// 留空时按外观取：时间线左右各留一点，封面贴边。
    var horizontalInset: CGFloat? = nil
    @ViewBuilder let content: () -> Content

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @ScaledMetric(relativeTo: .subheadline) private var timelineCardHeight = SongTimelineRowMetrics.timelineCardHeight
    @ScaledMetric(relativeTo: .subheadline) private var artworkCapsuleHeight = SongTimelineRowMetrics.artworkCapsuleHeight
    @State private var width: CGFloat = 0

    var body: some View {
        let style = appearance.timelineStyle ?? .timeline
        // 只用来定中轴位置和首尾留白，与序号、书写方向无关（中轴按前缘量，背景层自己会镜像）。
        let geometry = SongTimelineGeometry(
            style: style,
            containerWidth: width,
            ordinal: 1,
            cardHeight: style == .timeline ? timelineCardHeight : artworkCapsuleHeight,
            accessibilitySize: dynamicTypeSize.isAccessibilitySize,
            rightToLeft: false
        )
        let inset = horizontalInset ?? (style == .timeline ? SongTimelineRowMetrics.timelineHorizontalInset : 0)
        LazyVStack(spacing: 0) {
            content()
        }
        .scrollTargetLayout()
        .frame(maxWidth: .infinity)
        .background(alignment: .leading) {
            SongTimelinePalette(colorScheme: colorScheme, contrast: contrast).axis(style)
                .frame(width: 1)
                .padding(.leading, max(geometry.axisX - 0.5, 0))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .environment(\.songTimelineWidth, width)
        .padding(.horizontal, inset)
        .padding(.vertical, geometry.verticalOverflow + SongTimelineRowMetrics.stackVerticalPadding)
    }
}

/// 两种外观里线、节点、玻璃的颜色。深色按设计稿（黑底、白色细线与描边）；
/// 浅色换成浅灰卡片、黑色细线；「增强对比度」时线与描边加深。
private struct SongTimelinePalette {
    let colorScheme: ColorScheme
    let contrast: ColorSchemeContrast

    private var isDark: Bool { colorScheme == .dark }
    private var boost: Double { contrast == .increased ? 1.8 : 1 }

    func axis(_ style: SongTimelineGeometry.Style) -> Color {
        let base: Double = switch style {
        case .timeline: isDark ? 0.2 : 0.13
        case .artwork: isDark ? 0.09 : 0.07
        }
        return (isDark ? Color.white : Color.black).opacity(min(base * boost, 0.6))
    }

    func node(_ style: SongTimelineGeometry.Style) -> Color {
        let base: Double = switch style {
        case .timeline: isDark ? 0.62 : 0.32
        case .artwork: isDark ? 0.38 : 0.26
        }
        return (isDark ? Color.white : Color.black).opacity(min(base * boost, 0.9))
    }

    /// 正在播放那一行的节点与卡片光晕：深色是白光，浅色白光看不见，换成主题色。
    var glow: Color {
        isDark ? .white : .accentColor
    }

    var artworkEdge: Color {
        isDark ? Color.white.opacity(0.14 * boost) : Color.black.opacity(0.08 * boost)
    }
}

/// 卡片与胶囊的「玻璃」。
///
/// 不用材质做实时模糊：列表一屏十来行，每行一块背景模糊，滚动时每帧都要各自重采样背后的画面，
/// 不透明底上的玻璃卡片叠在一个滚动区里就会掉帧（见 `PMCard` 的说明）。这里用分层的半透明填充、
/// 左上的高光和渐变描边做出玻璃的样子：深色胶囊压在封面上时封面透出来一点、被压暗，字照样清楚。
/// 「降低透明度」时填充改成不透明。正在播放、多选选中与定位强调的描边也画在这里。
private struct SongTimelineGlass: View {
    enum Surface { case card, capsule }

    let cornerRadius: CGFloat
    let surface: Surface
    var isPlaying = false
    var isSelected = false

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.songLocationEmphasis) private var locationEmphasis

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let isDark = colorScheme == .dark
        let glow = SongTimelinePalette(colorScheme: colorScheme, contrast: contrast).glow
        shape.fill(fill(isDark: isDark))
            .overlay {
                if !reduceTransparency {
                    shape.fill(LinearGradient(
                        colors: [Color.white.opacity(isDark ? 0.1 : 0.5), Color.white.opacity(0)],
                        startPoint: .topLeading,
                        endPoint: .center
                    ))
                }
            }
            .overlay {
                if isPlaying && isDark {
                    shape.fill(Color.white.opacity(0.05))
                }
            }
            .overlay {
                if isSelected {
                    shape.fill(Color.accentColor.opacity(isDark ? 0.16 : 0.1))
                }
            }
            .overlay {
                shape.strokeBorder(border(isDark: isDark), lineWidth: 1)
            }
            .overlay {
                if isPlaying {
                    // 只有正在播的那一行有这两层光晕，阴影的开销只花在它身上。
                    shape.strokeBorder(glow.opacity(isDark ? 0.78 : 0.9), lineWidth: isDark ? 1.2 : 1.5)
                        .shadow(color: glow.opacity(isDark ? 0.4 : 0.35), radius: 8)
                        .shadow(color: glow.opacity(isDark ? 0.18 : 0.14), radius: 18)
                }
            }
            .overlay {
                if isSelected {
                    shape.strokeBorder(Color.accentColor, lineWidth: 1.5)
                }
            }
            .overlay {
                shape.strokeBorder(Color.accentColor, lineWidth: 2)
                    .shadow(color: Color.accentColor.opacity(isDark ? 0.55 : 0.35), radius: 7)
                    .opacity(locationEmphasis)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private func fill(isDark: Bool) -> Color {
        switch (surface, isDark) {
        case (.card, true):
            Color(red: 0.085, green: 0.09, blue: 0.105)
        case (.card, false):
            Color(red: 0.955, green: 0.96, blue: 0.97)
        case (.capsule, true):
            Color(red: 0.05, green: 0.055, blue: 0.07).opacity(reduceTransparency ? 1 : 0.74)
        case (.capsule, false):
            Color.white.opacity(reduceTransparency ? 1 : 0.8)
        }
    }

    private func border(isDark: Bool) -> LinearGradient {
        let boost = contrast == .increased ? 1.8 : 1.0
        let colors: [Color] = if isDark {
            [Color.white.opacity(0.34 * boost), Color.white.opacity(0.07 * boost), Color.white.opacity(0.18 * boost)]
        } else if surface == .capsule {
            [Color.white.opacity(0.9), Color.black.opacity(0.1 * boost)]
        } else {
            [Color.black.opacity(0.05 * boost), Color.black.opacity(0.12 * boost)]
        }
        return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

/// 卡片（胶囊）里的歌名与艺人。外面的行固定从左往右排，这里换回原来的书写方向，字照常靠前对齐。
private struct SongTimelineLabels: View {
    let song: Song
    let title: String
    let artist: String?
    let isUnavailable: Bool
    let titleLines: Int
    let layoutDirection: LayoutDirection

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(verbatim: title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(titleLines)
                    .minimumScaleFactor(0.8)
                SongContentRatingBadge(song: song)
            }
            if isUnavailable {
                Label("song_row_source_unreachable", systemImage: "wifi.slash")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else if let artist, !artist.isEmpty {
                Text(verbatim: artist)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .environment(\.layoutDirection, layoutDirection)
        .accessibilityHidden(true)
    }
}

/// 中轴上的节点。多选时换成勾选圈；正在播放的那一行节点更大、带一点光；定位强调时外面套一圈主题色。
private struct SongTimelineNode: View {
    let geometry: SongTimelineGeometry
    let isPlaying: Bool
    let isSelected: Bool?

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.songLocationEmphasis) private var locationEmphasis

    var body: some View {
        let palette = SongTimelinePalette(colorScheme: colorScheme, contrast: contrast)
        ZStack {
            if let isSelected {
                SongSelectionCheckmark(isSelected: isSelected)
                    .background { Circle().fill(.background).padding(1) }
            } else if isPlaying {
                Circle()
                    .fill(palette.glow)
                    .frame(width: 10, height: 10)
                    .shadow(color: palette.glow.opacity(0.7), radius: 5)
            } else {
                Circle()
                    .fill(palette.node(geometry.style))
                    .frame(width: geometry.style == .timeline ? 7 : 5, height: geometry.style == .timeline ? 7 : 5)
            }
            Circle()
                .strokeBorder(Color.accentColor, lineWidth: 1.5)
                .frame(width: 20, height: 20)
                .shadow(color: Color.accentColor.opacity(0.45), radius: 5)
                .opacity(locationEmphasis)
        }
        .position(geometry.node)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// 正在播放的那首封面上的播放标记；起播还在加载时换成转圈。
private struct SongTimelinePlayGlyph: View {
    let diameter: CGFloat
    let isLoading: Bool

    var body: some View {
        ZStack {
            Circle().fill(Color.black.opacity(0.48))
            Circle().strokeBorder(Color.white.opacity(0.4), lineWidth: 1)
            if isLoading {
                ProgressView()
                    .controlSize(diameter < 32 ? .mini : .small)
                    .tint(.white)
            } else {
                Image(systemName: "play.fill")
                    .font(.system(size: max(diameter * 0.4, 9), weight: .bold))
                    .foregroundStyle(.white)
                    // 三角形的重心偏左，往右挪一点看起来才居中。
                    .offset(x: diameter * 0.04)
            }
        }
        .frame(width: diameter, height: diameter)
        .accessibilityHidden(true)
    }
}

/// 离线状态角标。进度更新只在角标里，不让整行重建。
private struct SongTimelineOfflineBadge: View {
    @Environment(SourceManager.self) private var sourceManager
    let song: Song
    let size: CGFloat

    var body: some View {
        let snapshot = song.sourceID == AppleMusicLibraryService.systemSourceID
            ? OfflineAudioCacheSnapshot.notCached
            : sourceManager.offlineAudioSnapshotEntry(for: song).snapshot
        if snapshot.state != .notCached {
            OfflineAudioStatusBadge(snapshot: snapshot)
                .frame(width: size, height: size)
                .background(Circle().fill(Color.black.opacity(0.45)))
                // 角标压在封面上，灰色的「已缓存」按深色画才看得清。
                .environment(\.colorScheme, .dark)
        }
    }
}

/// 一行的命中形状：卡片（胶囊）、封面与节点那一段，坐标与行内绘制相同。
/// 三块互相重叠，用并集合成，不靠子路径的绕向。
private struct SongTimelineHitShape: Shape {
    let geometry: SongTimelineGeometry

    func path(in rect: CGRect) -> Path {
        Path(roundedRect: geometry.card, cornerRadius: geometry.cardCornerRadius, style: .continuous)
            .union(Path(geometry.artworkHitRect))
            .union(Path(geometry.nodeHitRect))
            .applying(CGAffineTransform(translationX: rect.minX, y: rect.minY))
    }
}

/// 长按菜单抬起的预览：只取卡片（胶囊）。大封面伸出了这一行的框，抬起来只会剩半张。
private struct SongTimelineCardShape: Shape {
    let geometry: SongTimelineGeometry

    func path(in rect: CGRect) -> Path {
        Path(roundedRect: geometry.card.offsetBy(dx: rect.minX, dy: rect.minY),
             cornerRadius: geometry.cardCornerRadius, style: .continuous)
    }
}

private extension View {
    /// 按行内的物理坐标摆到 `rect`。
    func songTimelinePlaced(_ rect: CGRect) -> some View {
        frame(width: max(rect.width, 0), height: max(rect.height, 0))
            .position(x: rect.midX, y: rect.midY)
    }

    /// 行内一律按物理坐标排；从右往左书写时 `SongTimelineGeometry` 已经镜像好，这里固定从左往右，
    /// 命中与预览形状也在同一套坐标里。字由 `SongTimelineLabels` 自己换回原方向。
    func songTimelineRowFrame(
        _ geometry: SongTimelineGeometry,
        title: String,
        artist: String?
    ) -> some View {
        frame(width: geometry.containerWidth, height: geometry.rowHeight, alignment: .topLeading)
            .contentShape(.interaction, SongTimelineHitShape(geometry: geometry))
            // 命中形状不带进辅助功能：朗读焦点框与激活点仍是整个槽位（中心落在节点上，点得到）。
            .contentShape(.accessibility, Rectangle())
            #if os(iOS)
            .contentShape(.contextMenuPreview, SongTimelineCardShape(geometry: geometry))
            #endif
            .environment(\.layoutDirection, .leftToRight)
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: [title, artist].compactMap { $0 }.joined(separator: " — ")))
    }
}

// MARK: - 时间线

/// 时间线外观的一行：中轴上一个节点、一段短连线，连着左右交替的玻璃卡片
/// （外侧方形封面，内侧歌名与艺人）。正在播放的卡片描边提亮、带一圈光晕，封面上压播放标记。
/// 槽位高度固定；随滚动的淡入淡出只改绘制，不改布局和命中。
struct SongTimelineRowContent: View {
    let song: Song
    let title: String
    let artist: String?
    /// 在列表里排第几（从 1 数），决定在中轴哪一侧。
    let ordinal: Int
    var isPlaying = false
    var isLoading = false
    var isUnavailable = false
    var isReadingDetails = false
    /// 非 nil 时在多选：节点换成勾选圈，不显示离线角标。
    var isSelected: Bool? = nil

    @Environment(\.songTimelineWidth) private var containerWidth
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .subheadline) private var cardHeight = SongTimelineRowMetrics.timelineCardHeight

    var body: some View {
        let geometry = SongTimelineGeometry(
            style: .timeline,
            containerWidth: containerWidth,
            ordinal: ordinal,
            cardHeight: cardHeight,
            accessibilitySize: dynamicTypeSize.isAccessibilitySize,
            rightToLeft: layoutDirection == .rightToLeft
        )
        let palette = SongTimelinePalette(colorScheme: colorScheme, contrast: contrast)
        let reducesMotion = reduceMotion
        ZStack(alignment: .topLeading) {
            connector(geometry, color: palette.axis(.timeline))
            card(geometry, palette: palette)
                // 先合成一层再整体变淡，否则封面和字会各自透出底下的玻璃。
                .compositingGroup()
                .visualEffect { effect, proxy in
                    songTimelineCardEffect(effect, proxy: proxy, cardMinY: geometry.card.minY,
                                           rowHeight: geometry.rowHeight, reduceMotion: reducesMotion)
                }
                .songTimelinePlaced(geometry.card)
            SongTimelineNode(geometry: geometry, isPlaying: isPlaying, isSelected: isSelected)
        }
        .songTimelineRowFrame(geometry, title: title, artist: artist)
    }

    private var contentOpacity: Double {
        isUnavailable ? 0.45 : (isReadingDetails ? 0.65 : 1)
    }

    /// 卡片内侧边到中轴的一小段横线。
    private func connector(_ geometry: SongTimelineGeometry, color: Color) -> some View {
        let inner = geometry.isOnLeft ? geometry.card.maxX : geometry.card.minX
        let start = min(inner, geometry.axisX)
        let end = max(inner, geometry.axisX)
        return Rectangle()
            .fill(color)
            .frame(width: max(end - start, 0), height: 1)
            .position(x: (start + end) / 2, y: geometry.node.y)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private func card(_ geometry: SongTimelineGeometry, palette: SongTimelinePalette) -> some View {
        let origin = geometry.card.origin
        let side = geometry.artwork.width
        let radius = geometry.artworkCornerRadius
        return ZStack(alignment: .topLeading) {
            SongTimelineGlass(cornerRadius: geometry.cardCornerRadius, surface: .card,
                              isPlaying: isPlaying, isSelected: isSelected == true)
            CachedArtworkView(
                coverRef: song.coverArtFileName, songID: song.id, size: side, cornerRadius: radius,
                sourceID: song.sourceID, filePath: song.filePath, fileFormat: song.fileFormat
            )
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(palette.artworkEdge, lineWidth: 0.5)
            }
            .overlay {
                if isPlaying {
                    SongTimelinePlayGlyph(diameter: max(side * 0.5, 22), isLoading: isLoading)
                        .pmFadeTransition()
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if isSelected == nil {
                    SongTimelineOfflineBadge(song: song, size: 20)
                        .offset(x: 4, y: 4)
                }
            }
            .opacity(contentOpacity)
            .accessibilityHidden(true)
            .songTimelinePlaced(geometry.artwork.offsetBy(dx: -origin.x, dy: -origin.y))
            SongTimelineLabels(
                song: song, title: title, artist: artist, isUnavailable: isUnavailable,
                titleLines: geometry.isSingleColumn ? 3 : 2, layoutDirection: layoutDirection
            )
            .opacity(contentOpacity)
            .songTimelinePlaced(geometry.labels.offsetBy(dx: -origin.x, dy: -origin.y))
        }
        .frame(width: geometry.card.width, height: geometry.card.height)
    }
}

// MARK: - 封面

/// 封面外观的一行：左右交替、带透视的大封面伸出屏幕边，内侧边缘压一块玻璃胶囊写歌名与艺人；
/// 中间一条极淡的中轴，每首歌一个小节点。正在播放的那首封面露出来的一段上压播放标记，胶囊描边提亮。
///
/// 大封面比槽位高，伸进上下邻居同一侧空着的半边；槽位高度固定，转角、视差都只改绘制。
/// 胶囊为什么不做实时模糊见 `SongTimelineGlass`。
struct SongArtworkRowContent: View {
    let song: Song
    let title: String
    let artist: String?
    /// 在列表里排第几（从 1 数），决定在中轴哪一侧。
    let ordinal: Int
    var isPlaying = false
    var isLoading = false
    var isUnavailable = false
    var isReadingDetails = false
    /// 非 nil 时在多选：节点换成勾选圈，不显示离线角标。
    var isSelected: Bool? = nil

    @Environment(\.songTimelineWidth) private var containerWidth
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .subheadline) private var capsuleHeight = SongTimelineRowMetrics.artworkCapsuleHeight

    var body: some View {
        let geometry = SongTimelineGeometry(
            style: .artwork,
            containerWidth: containerWidth,
            ordinal: ordinal,
            cardHeight: capsuleHeight,
            accessibilitySize: dynamicTypeSize.isAccessibilitySize,
            rightToLeft: layoutDirection == .rightToLeft
        )
        let reducesMotion = reduceMotion
        ZStack(alignment: .topLeading) {
            cover(geometry)
                .visualEffect { effect, proxy in
                    songArtworkCoverEffect(effect, proxy: proxy, turn: geometry.artworkTurn,
                                           roll: geometry.artworkRoll, coverMinY: geometry.artwork.minY,
                                           rowHeight: geometry.rowHeight, reduceMotion: reducesMotion)
                }
                .songTimelinePlaced(geometry.artwork)
            capsule(geometry)
                .songTimelinePlaced(geometry.card)
            SongTimelineNode(geometry: geometry, isPlaying: isPlaying, isSelected: isSelected)
        }
        .songTimelineRowFrame(geometry, title: title, artist: artist)
    }

    private var contentOpacity: Double {
        isUnavailable ? 0.45 : (isReadingDetails ? 0.65 : 1)
    }

    private func cover(_ geometry: SongTimelineGeometry) -> some View {
        let side = geometry.artwork.width
        let radius = geometry.artworkCornerRadius
        let edge = SongTimelinePalette(colorScheme: colorScheme, contrast: contrast).artworkEdge
        return CachedArtworkView(
            coverRef: song.coverArtFileName, songID: song.id, size: side, cornerRadius: radius,
            sourceID: song.sourceID, filePath: song.filePath, fileFormat: song.fileFormat
        )
        .overlay {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(edge, lineWidth: 0.5)
        }
        .overlay(alignment: .topLeading) {
            if isPlaying {
                SongTimelinePlayGlyph(diameter: side * 0.3, isLoading: isLoading)
                    .position(x: side * geometry.artworkGlyphCenterX, y: side / 2)
                    .pmFadeTransition()
            }
        }
        // 外侧伸出了屏幕，角标放在内侧上角；胶囊压在中间，碰不到。
        .overlay(alignment: geometry.isOnLeft ? .topTrailing : .topLeading) {
            if isSelected == nil {
                SongTimelineOfflineBadge(song: song, size: 24)
                    .padding(8)
            }
        }
        .opacity(contentOpacity)
        .accessibilityHidden(true)
    }

    private func capsule(_ geometry: SongTimelineGeometry) -> some View {
        SongTimelineGlass(cornerRadius: geometry.cardCornerRadius, surface: .capsule,
                          isPlaying: isPlaying, isSelected: isSelected == true)
            .overlay(alignment: .topLeading) {
                SongTimelineLabels(
                    song: song, title: title, artist: artist, isUnavailable: isUnavailable,
                    titleLines: geometry.isSingleColumn ? 2 : 1, layoutDirection: layoutDirection
                )
                .opacity(contentOpacity)
                .songTimelinePlaced(geometry.labels.offsetBy(dx: -geometry.card.minX, dy: -geometry.card.minY))
            }
            .frame(width: geometry.card.width, height: geometry.card.height)
    }
}

// MARK: - 随滚动的效果
//
// `visualEffect` 的闭包是 @Sendable 的，不继承视图的 MainActor 隔离：闭包里只调用
// 下面这些文件内自由函数，用到的环境值先在 body 里取成局部值。

/// 这一视图在可视区里的位置：可视区顶部（视图自己的坐标系里）与可视区高度。
/// 滚动区的布局框本身已经让开了导航栏、页内查找框和底部的迷你播放条，不用再扣内边距。
private func songListVisibleArea(_ proxy: GeometryProxy) -> (top: CGFloat, height: CGFloat)? {
    guard let bounds = proxy.bounds(of: .scrollView(axis: .vertical)), bounds.height > 0 else { return nil }
    return (bounds.minY, bounds.height)
}

/// - Parameter cardMinY: 卡片上沿在槽位里的位置，用来从卡片量出槽位在可视区里的位置。
private func songTimelineCardEffect(
    _ effect: EmptyVisualEffect,
    proxy: GeometryProxy,
    cardMinY: CGFloat,
    rowHeight: CGFloat,
    reduceMotion: Bool
) -> some VisualEffect {
    var motion = SongTimelineScrollMotion.identity
    if let area = songListVisibleArea(proxy) {
        motion = SongTimelineScrollMotion(
            style: .timeline,
            rowMinY: -area.top - cardMinY,
            rowHeight: rowHeight,
            viewportHeight: area.height,
            reduceMotion: reduceMotion
        )
    }
    return effect
        .scaleEffect(motion.cardScale)
        .opacity(motion.cardOpacity)
}

/// 大封面的基础转角（`SongTimelineGeometry` 给的，减少动态效果时也保留）加上随滚动多转的一点、缩放与视差。
/// - Parameter coverMinY: 封面上沿在槽位里的位置（伸出槽位时为负）。
private func songArtworkCoverEffect(
    _ effect: EmptyVisualEffect,
    proxy: GeometryProxy,
    turn: Double,
    roll: Double,
    coverMinY: CGFloat,
    rowHeight: CGFloat,
    reduceMotion: Bool
) -> some VisualEffect {
    var motion = SongTimelineScrollMotion.identity
    if let area = songListVisibleArea(proxy) {
        motion = SongTimelineScrollMotion(
            style: .artwork,
            rowMinY: -area.top - coverMinY,
            rowHeight: rowHeight,
            viewportHeight: area.height,
            reduceMotion: reduceMotion
        )
    }
    let direction: Double = turn < 0 ? -1 : 1
    return effect
        .rotation3DEffect(
            .degrees(turn + direction * motion.extraTurn),
            axis: (x: 0, y: 1, z: 0),
            perspective: SongTimelineGeometry.perspective
        )
        .rotationEffect(.degrees(roll))
        .scaleEffect(motion.artworkScale)
        .offset(y: motion.artworkShift)
}
