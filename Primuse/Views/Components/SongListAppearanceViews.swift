import SwiftUI
import PrimuseKit

/// 曲库「歌曲」页的三种外观：列表、方块（封面网格）、聚焦（单列大卡片）。
/// 旧版存下的 `timeline`、`artwork` 读到后回落到列表。
enum SongListAppearance: String, CaseIterable {
    case list, tiles, focus

    static let storageKey = "songListAppearance"

    static func resolved(_ value: String) -> Self {
        Self(rawValue: value) ?? .list
    }

    var titleKey: LocalizedStringKey {
        switch self {
        case .list: "song_list_layout_list"
        case .tiles: "song_list_layout_tiles"
        case .focus: "song_list_layout_focus"
        }
    }

    var symbol: String {
        switch self {
        case .list: "list.bullet"
        case .tiles: "square.grid.2x2"
        case .focus: "rectangle.expand.vertical"
        }
    }
}

extension EnvironmentValues {
    @Entry var songListAppearance: SongListAppearance = .list
    @Entry var songTileLayout: SongTileLayout = SongTileLayout()
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

/// 方块与聚焦外观长按时，抬起的预览按卡片圆角裁；列表保持系统默认。
struct SongListRowPreviewShape: ViewModifier {
    let appearance: SongListAppearance
    @Environment(\.songTileLayout) private var tileLayout

    func body(content: Content) -> some View {
        #if os(iOS)
        switch appearance {
        case .list:
            content
        case .tiles:
            content.contentShape(.contextMenuPreview, RoundedRectangle(
                cornerRadius: SongTileContent.cornerRadius(side: tileLayout.side), style: .continuous))
        case .focus:
            content.contentShape(.contextMenuPreview, RoundedRectangle(
                cornerRadius: SongFocusRowMetrics.cornerRadius, style: .continuous))
        }
        #else
        content
        #endif
    }
}

// MARK: - 网格与可视区

/// 方块网格这一次排成几列、一块多大。由网格容器量一次宽度算出，经环境传给每一块。
struct SongTileLayout: Equatable, Sendable {
    var columns = 2
    var side: CGFloat = 170

    init(columns: Int = 2, side: CGFloat = 170) {
        self.columns = max(columns, 1)
        self.side = side
    }

    init(containerWidth: CGFloat, leadingInset: CGFloat, trailingInset: CGFloat, accessibilitySize: Bool) {
        let available = containerWidth - leadingInset - trailingInset
        let columns = SongTileGridPolicy.columnCount(availableWidth: available, accessibilitySize: accessibilitySize)
        self.init(columns: columns, side: SongTileGridPolicy.tileSide(availableWidth: available, columns: columns))
    }

    var gridItems: [GridItem] {
        Array(
            repeating: GridItem(.flexible(), spacing: SongTileGridPolicy.spacing, alignment: .top),
            count: columns
        )
    }
}

/// 方块网格。每首歌仍是 `ForEach` 里的一个子视图、带着调用方给的身份，
/// 列数随宽度换的是 `columns`，不换视图树（横竖屏切换时滚动位置与长按菜单都还在）。
struct SongTileGrid<Content: View>: View {
    var leadingInset: CGFloat = SongTileGridPolicy.horizontalInset
    var trailingInset: CGFloat = SongTileGridPolicy.horizontalInset
    @ViewBuilder let content: () -> Content

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var width: CGFloat = 0

    var body: some View {
        let layout = SongTileLayout(
            containerWidth: width,
            leadingInset: leadingInset,
            trailingInset: trailingInset,
            accessibilitySize: dynamicTypeSize.isAccessibilitySize
        )
        LazyVGrid(columns: layout.gridItems, spacing: SongTileGridPolicy.spacing) {
            content()
        }
        // 与列表一样一个位置一个滚动目标：字母索引与定位直接按身份跳过去。
        .scrollTargetLayout()
        .padding(.leading, leadingInset)
        .padding(.trailing, trailingInset)
        .environment(\.songTileLayout, layout)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }
}

// MARK: - 方块

/// 一首歌一块：封面铺满，底部压暗后叠歌名与艺人。随滚动的层次变化见 `SongTileScrollMotion`。
///
/// 整块不含玻璃材质：3D 合成会把玻璃的背景采样变成灰底，所以角标都用实色底。
struct SongTileContent: View {
    let song: Song
    let title: String
    let artist: String?
    /// 在列表里排第几（从 1 数），用来算列号与相位。
    let ordinal: Int
    var isPlaying = false
    var isLoading = false
    var isUnavailable = false
    var isReadingDetails = false
    var isSelected: Bool? = nil

    @Environment(\.songTileLayout) private var layout
    @Environment(\.songLocationEmphasis) private var locationEmphasis
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    static func cornerRadius(side: CGFloat) -> CGFloat {
        min(max(side * 0.085, 12), 18)
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Self.cornerRadius(side: layout.side), style: .continuous)
        let column = SongTileGridPolicy.column(forIndex: ordinal - 1, columns: layout.columns)
        let columns = layout.columns
        let reducesMotion = reduceMotion
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay { artwork(reducesMotion: reducesMotion) }
            .overlay { scrim }
            .overlay(alignment: .bottomLeading) { labels }
            .overlay(alignment: .topLeading) { leadingBadge }
            .overlay(alignment: .topTrailing) { playingBadge }
            .clipShape(shape)
            .overlay { border(shape) }
            .opacity(isUnavailable ? 0.45 : (isReadingDetails ? 0.7 : 1))
            // 先合成一层再整体变透明，否则字和压暗层会各自透出底下的封面。
            .compositingGroup()
            .visualEffect { effect, proxy in
                songTileEffect(effect, proxy: proxy, column: column, columns: columns,
                               reduceMotion: reducesMotion)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: [title, artist].compactMap { $0 }.joined(separator: " — ")))
    }

    private func artwork(reducesMotion: Bool) -> some View {
        let overscan = SongTileScrollMotion.artworkOverscan
        return CachedArtworkView(
            coverRef: song.coverArtFileName, songID: song.id,
            size: max(layout.side, 120) * overscan, cornerRadius: 0,
            sourceID: song.sourceID, filePath: song.filePath, fileFormat: song.fileFormat,
            fillsProposedSize: true
        )
        // 封面比块略大，视差移动几个点时四边不露底；缩放不改变布局。
        .scaleEffect(overscan)
        .visualEffect { effect, proxy in
            songTileParallaxEffect(effect, proxy: proxy, reduceMotion: reducesMotion)
        }
        .accessibilityHidden(true)
    }

    private var scrim: some View {
        LinearGradient(stops: [
            .init(color: .black.opacity(0), location: 0.36),
            .init(color: .black.opacity(0.26), location: 0.6),
            .init(color: .black.opacity(0.74), location: 1)
        ], startPoint: .top, endPoint: .bottom)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var labels: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            if isUnavailable {
                Label("song_row_source_unreachable", systemImage: "wifi.slash")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.82))
                    .lineLimit(1)
            } else if let artist, !artist.isEmpty {
                Text(verbatim: artist)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.78))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 11)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var leadingBadge: some View {
        if let isSelected {
            SongTileSelectionMark(isSelected: isSelected)
                .padding(8)
        } else {
            SongTileOfflineBadge(song: song)
                .padding(8)
        }
    }

    @ViewBuilder
    private var playingBadge: some View {
        if isPlaying {
            ZStack {
                Circle().fill(Color.accentColor)
                if isLoading {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(.white)
                } else {
                    Image(systemName: "waveform")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.textOnAccent)
                        .symbolEffect(.variableColor.iterative)
                }
            }
            .frame(width: 26, height: 26)
            .shadow(color: .black.opacity(0.28), radius: 3, y: 1)
            .padding(8)
            .pmFadeTransition()
            .accessibilityHidden(true)
        }
    }

    private func border(_ shape: RoundedRectangle) -> some View {
        ZStack {
            shape.strokeBorder(
                colorScheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.06),
                lineWidth: 0.5
            )
            if isPlaying || isSelected == true {
                shape.strokeBorder(Color.accentColor, lineWidth: 2.5)
            }
            shape.strokeBorder(Color.accentColor, lineWidth: 3)
                .shadow(color: Color.accentColor.opacity(colorScheme == .dark ? 0.6 : 0.4), radius: 8)
                .opacity(locationEmphasis)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// 进度更新只在角标里，不让整块重建。
private struct SongTileOfflineBadge: View {
    @Environment(SourceManager.self) private var sourceManager
    let song: Song

    var body: some View {
        let snapshot = song.sourceID == AppleMusicLibraryService.systemSourceID
            ? OfflineAudioCacheSnapshot.notCached
            : sourceManager.offlineAudioSnapshotEntry(for: song).snapshot
        if snapshot.state != .notCached {
            OfflineAudioStatusBadge(snapshot: snapshot)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.black.opacity(0.45)))
                // 角标压在封面上，灰色的「已缓存」按深色画才看得清。
                .environment(\.colorScheme, .dark)
        }
    }
}

private struct SongTileSelectionMark: View {
    let isSelected: Bool

    var body: some View {
        ZStack {
            Circle().fill(isSelected ? Color.accentColor : Color.black.opacity(0.28))
            Circle().strokeBorder(Color.white, lineWidth: 1.5)
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.textOnAccent)
            }
        }
        .frame(width: 24, height: 24)
        .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
        .accessibilityHidden(true)
    }
}

// MARK: - 聚焦

enum SongFocusRowMetrics {
    /// 卡片高度（随动态字号放大）。
    static let baseHeight: CGFloat = 84
    /// 封面边长（随动态字号放大，但不超过卡片留出的高度）。
    static let baseCover: CGFloat = 64
    /// 卡片上下各留的距离；行距 = 卡高 + 2 × 这个值。
    static let verticalInset: CGFloat = 5
    static let cornerRadius: CGFloat = 18

    /// 卡片第二行：「艺人 · 专辑」，缺哪个就不写哪个。
    static func subtitle(artist: String?, album: String?) -> String? {
        let parts = [artist, album].compactMap { value -> String? in
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
            return value
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// 单列大卡片：左侧大封面、歌名、艺人·专辑，右侧时长与状态。
/// 行高固定，随滚动的缩放、收拢和封面转角都只改绘制，不参与布局和命中。
struct SongFocusRowContent<Accessory: View>: View {
    let song: Song
    let title: String
    let subtitle: String?
    var isPlaying = false
    var isLoading = false
    var isUnavailable = false
    var isReadingDetails = false
    var isSelected: Bool? = nil
    @ViewBuilder let accessory: () -> Accessory

    @Environment(\.songLocationEmphasis) private var locationEmphasis
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.layoutDirection) private var layoutDirection
    @ScaledMetric(relativeTo: .body) private var rowHeight = SongFocusRowMetrics.baseHeight
    @ScaledMetric(relativeTo: .body) private var scaledCover = SongFocusRowMetrics.baseCover

    var body: some View {
        let height = rowHeight
        let pitch = rowHeight + SongFocusRowMetrics.verticalInset * 2
        let cover = max(min(scaledCover, rowHeight - 18), 40)
        let reducesMotion = reduceMotion
        let shape = RoundedRectangle(cornerRadius: SongFocusRowMetrics.cornerRadius, style: .continuous)
        HStack(spacing: 12) {
            if let isSelected {
                SongSelectionCheckmark(isSelected: isSelected)
            }
            coverView(size: cover, cardHeight: height, pitch: pitch, reducesMotion: reducesMotion)
                .opacity(contentOpacity)
            labels
                .opacity(contentOpacity)
            Spacer(minLength: 4)
            trailingStatus
            accessory()
        }
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .background { cardBackground(shape) }
        .compositingGroup()
        .visualEffect { effect, proxy in
            songFocusCardEffect(effect, proxy: proxy, pitch: pitch, cardHeight: height,
                                reduceMotion: reducesMotion)
        }
    }

    private var contentOpacity: Double {
        isUnavailable ? 0.45 : (isReadingDetails ? 0.65 : 1)
    }

    private func coverView(size: CGFloat, cardHeight: CGFloat, pitch: CGFloat, reducesMotion: Bool) -> some View {
        let turnSign: Double = layoutDirection == .rightToLeft ? -1 : 1
        let radius = size * 0.16
        return ZStack {
            // 只有居中的那一两行看得见这层阴影。
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(Color.black.opacity(colorScheme == .dark ? 0.6 : 0.3))
                .blur(radius: 7)
                .offset(y: 5)
                .visualEffect { effect, proxy in
                    songFocusShadowEffect(effect, proxy: proxy, pitch: pitch, cardHeight: cardHeight,
                                          reduceMotion: reducesMotion)
                }
            CachedArtworkView(
                coverRef: song.coverArtFileName, songID: song.id, size: size, cornerRadius: radius,
                sourceID: song.sourceID, filePath: song.filePath, fileFormat: song.fileFormat
            )
            if isPlaying {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Color.black.opacity(0.35))
                    .pmFadeTransition()
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                        .pmFadeTransition()
                } else {
                    Image(systemName: "waveform")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.white)
                        .symbolEffect(.variableColor.iterative)
                        .pmFadeTransition()
                }
            }
        }
        .frame(width: size, height: size)
        .visualEffect { effect, proxy in
            songFocusCoverEffect(effect, proxy: proxy, pitch: pitch, cardHeight: cardHeight,
                                 reduceMotion: reducesMotion, turnSign: turnSign)
        }
        .accessibilityHidden(true)
    }

    private var labels: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                // 卡片有两行字的高度：长歌名折成两行，不在窄屏上只剩前几个字。
                Text(verbatim: title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(isPlaying ? Color.accentColor : Color.primary)
                    .lineLimit(2)
                SongContentRatingBadge(song: song)
            }
            if isUnavailable {
                Label("song_row_source_unreachable", systemImage: "wifi.slash")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else if let subtitle {
                Text(verbatim: subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private var trailingStatus: some View {
        if song.duration > 0 {
            Text(verbatim: song.duration.formattedDuration)
                .font(.footnote)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
                .accessibilityHidden(true)
        }
    }

    private func cardBackground(_ shape: RoundedRectangle) -> some View {
        let isDark = colorScheme == .dark
        let fill: Color = if isPlaying {
            Color.accentColor.opacity(isDark ? 0.18 : 0.11)
        } else if isSelected == true {
            Color.accentColor.opacity(isDark ? 0.14 : 0.09)
        } else {
            Color.primary.opacity(isDark ? 0.075 : 0.045)
        }
        return shape.fill(fill)
            .overlay {
                shape.strokeBorder(
                    isPlaying ? Color.accentColor.opacity(0.45) : Color.primary.opacity(isDark ? 0.08 : 0.05),
                    lineWidth: isPlaying ? 1 : 0.5
                )
            }
            .overlay {
                shape.strokeBorder(Color.accentColor, lineWidth: 2)
                    .shadow(color: Color.accentColor.opacity(isDark ? 0.55 : 0.35), radius: 7)
                    .opacity(locationEmphasis)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

extension SongFocusRowContent where Accessory == EmptyView {
    /// 多选中用的精简卡：没有菜单，左侧换成勾选圈。
    init(song: Song, title: String, subtitle: String?, isPlaying: Bool = false, isSelected: Bool?) {
        self.init(song: song, title: title, subtitle: subtitle, isPlaying: isPlaying, isSelected: isSelected) {
            EmptyView()
        }
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

/// SwiftUI 绕 X 轴转正角度时上沿远离观看者；`SongTileScrollMotion.tilt` 以上沿朝向观看者为正。
private let songTileTiltSign: Double = -1

private func songTileEffect(
    _ effect: EmptyVisualEffect,
    proxy: GeometryProxy,
    column: Int,
    columns: Int,
    reduceMotion: Bool
) -> some VisualEffect {
    var motion = SongTileScrollMotion.identity
    if let area = songListVisibleArea(proxy) {
        motion = SongTileScrollMotion(
            tileMinY: -area.top,
            tileHeight: proxy.size.height,
            viewportHeight: area.height,
            column: column,
            columnCount: columns,
            reduceMotion: reduceMotion
        )
    }
    return effect
        .scaleEffect(motion.scale)
        .rotation3DEffect(
            .degrees(motion.tilt * songTileTiltSign),
            axis: (x: 1, y: 0, z: 0),
            perspective: SongTileScrollMotion.perspective
        )
        .opacity(motion.opacity)
        .brightness(-motion.dim)
}

private func songTileParallaxEffect(
    _ effect: EmptyVisualEffect,
    proxy: GeometryProxy,
    reduceMotion: Bool
) -> some VisualEffect {
    var shift: CGFloat = 0
    if !reduceMotion, let area = songListVisibleArea(proxy) {
        shift = SongTileScrollMotion.parallax(
            tileMidY: proxy.size.height / 2 - area.top,
            tileHeight: proxy.size.height,
            viewportHeight: area.height
        )
    }
    return effect.offset(y: shift)
}

/// 封面、阴影与整张卡的竖直中心重合，三处各自量出来的位置相同。
private func songFocusMotion(
    _ proxy: GeometryProxy,
    pitch: CGFloat,
    cardHeight: CGFloat,
    reduceMotion: Bool
) -> SongFocusScrollMotion {
    guard let area = songListVisibleArea(proxy) else { return .identity }
    return SongFocusScrollMotion(
        rowMidY: proxy.size.height / 2 - area.top,
        rowPitch: pitch,
        cardHeight: cardHeight,
        viewportHeight: area.height,
        reduceMotion: reduceMotion
    )
}

private func songFocusCardEffect(
    _ effect: EmptyVisualEffect,
    proxy: GeometryProxy,
    pitch: CGFloat,
    cardHeight: CGFloat,
    reduceMotion: Bool
) -> some VisualEffect {
    let motion = songFocusMotion(proxy, pitch: pitch, cardHeight: cardHeight, reduceMotion: reduceMotion)
    return effect
        .scaleEffect(motion.scale)
        .offset(y: motion.offset)
        .opacity(motion.opacity)
}

private func songFocusCoverEffect(
    _ effect: EmptyVisualEffect,
    proxy: GeometryProxy,
    pitch: CGFloat,
    cardHeight: CGFloat,
    reduceMotion: Bool,
    turnSign: Double
) -> some VisualEffect {
    let motion = songFocusMotion(proxy, pitch: pitch, cardHeight: cardHeight, reduceMotion: reduceMotion)
    return effect.rotation3DEffect(
        .degrees(motion.coverTurn * turnSign),
        axis: (x: 0, y: 1, z: 0),
        perspective: 0.6
    )
}

private func songFocusShadowEffect(
    _ effect: EmptyVisualEffect,
    proxy: GeometryProxy,
    pitch: CGFloat,
    cardHeight: CGFloat,
    reduceMotion: Bool
) -> some VisualEffect {
    let motion = songFocusMotion(proxy, pitch: pitch, cardHeight: cardHeight, reduceMotion: reduceMotion)
    return effect.opacity(motion.emphasis)
}
