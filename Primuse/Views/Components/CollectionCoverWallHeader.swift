import PrimuseKit
import SwiftUI

#if os(iOS)
/// 歌单与智能歌单详情页的「封面墙」头图（#114）：集合里不同专辑的封面拼成一面倾斜的墙，
/// 每隔几秒平滑换一次构图，同一张封面滑到新位置、新封面淡入、离开的淡出。
///
/// 功能契约只有三样：标题、一行摘要、这个集合里的歌。播放、下载、排序、批量选择都不经过这里。
/// 封面不够铺一面墙时（少于 `CoverWallLayoutPolicy.minimumDistinctCovers` 张）原样显示
/// 调用方给的 `fallback`，也就是这个页面原来的头部。
struct CollectionCoverWallHeader<Fallback: View>: View {
    private let title: String
    private let subtitle: String
    private let titleSymbol: String?
    private let coverIDs: [String]
    private let coverSongs: [String: Song]
    private let focusCoverID: String?
    private let wallHeight: CGFloat
    private let topInset: CGFloat
    private let fallback: Fallback

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var step = 0
    @State private var isVisible = false
    @State private var isLowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    @State private var thermalState = ProcessInfo.processInfo.thermalState

    /// - Parameters:
    ///   - songs: 集合里的歌，按页面上看到的顺序。只会扫前面一段。
    ///   - nowPlaying: 正在播放的歌。它的封面在这面墙里时会成为焦点。
    ///   - wallHeight: 墙面高度，含压在下沿的标题块。
    ///   - topInset: 页面让头图顶到屏幕上沿时状态栏加导航栏那一截。墙面往上多铺这么高，
    ///     返回键和工具栏按钮浮在墙上；为 0 时墙面从导航栏下面淡入。
    init(
        title: String,
        subtitle: String,
        titleSymbol: String? = nil,
        songs: [Song],
        nowPlaying: Song?,
        wallHeight: CGFloat,
        topInset: CGFloat = 0,
        @ViewBuilder fallback: () -> Fallback
    ) {
        self.title = title
        self.subtitle = subtitle
        self.titleSymbol = titleSymbol
        self.wallHeight = wallHeight
        self.topInset = max(0, topInset)
        self.fallback = fallback()

        let focusGroupKey = nowPlaying.map(CollectionCoverWall.groupKey(for:))
        let pooled = CollectionCoverWall.pool(from: songs, focusGroupKey: focusGroupKey)
        self.coverIDs = pooled.map(\.candidate.songID)
        self.coverSongs = Dictionary(
            pooled.map { ($0.candidate.songID, $0.element) },
            uniquingKeysWith: { first, _ in first }
        )
        self.focusCoverID = focusGroupKey.flatMap { key in
            pooled.first(where: { $0.candidate.groupKey == key })?.candidate.songID
        }
    }

    private var showsWall: Bool {
        CoverWallLayoutPolicy.prefersWall(distinctCoverCount: coverIDs.count)
    }

    /// 看不见、离开前台、开了「减弱动态效果」、低电量或机身发热时停在当前构图。
    private var isCycling: Bool {
        showsWall
            && isVisible
            && scenePhase == .active
            && !reduceMotion
            && !isLowPower
            && (thermalState == .nominal || thermalState == .fair)
    }

    var body: some View {
        if showsWall {
            wallHeader
        } else {
            fallback
        }
    }

    private var wallHeader: some View {
        ZStack(alignment: .bottom) {
            GeometryReader { proxy in
                wall(in: proxy.size)
            }
            .clipped()
            // 下沿融进页面底色：不画硬边，也不需要知道页面底色是什么。
            .mask {
                LinearGradient(stops: maskStops, startPoint: .top, endPoint: .bottom)
            }
            .accessibilityHidden(true)

            titleBlock
                .padding(.horizontal, 24)
                .padding(.bottom, 14)
        }
        .frame(height: wallHeight + topInset)
        .frame(maxWidth: .infinity)
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
        .onReceive(NotificationCenter.default.publisher(
            for: Notification.Name.NSProcessInfoPowerStateDidChange
        )) { _ in
            isLowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
        .onReceive(NotificationCenter.default.publisher(
            for: ProcessInfo.thermalStateDidChangeNotification
        )) { _ in
            thermalState = ProcessInfo.processInfo.thermalState
        }
        .task(id: isCycling) {
            guard isCycling else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(CoverWallLayoutPolicy.reflowInterval))
                if Task.isCancelled { break }
                step += 1
            }
        }
    }

    /// 不顶到上沿时墙面从导航栏下面淡入。顶到上沿时状态栏和按钮底下的那一截半透明地掺着页面底色,
    /// 时间、电量和按钮压在封面上也读得清; 往下照原样渐隐。
    private var maskStops: [Gradient.Stop] {
        guard topInset > 0 else {
            return [
                .init(color: .clear, location: 0),
                .init(color: .black, location: 0.16),
                .init(color: .black, location: 0.44),
                .init(color: .black.opacity(0.24), location: 0.78),
                .init(color: .clear, location: 1),
            ]
        }
        let total = wallHeight + topInset
        let wallTop = topInset / total
        let wallSpan = wallHeight / total
        return [
            .init(color: .black.opacity(0.45), location: 0),
            .init(color: .black, location: wallTop),
            .init(color: .black, location: wallTop + wallSpan * 0.44),
            .init(color: .black.opacity(0.24), location: wallTop + wallSpan * 0.78),
            .init(color: .clear, location: 1),
        ]
    }

    private var titleBlock: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                if let titleSymbol {
                    Image(systemName: titleSymbol)
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
                Text(title)
                    .font(.title2)
                    .fontWeight(.bold)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    /// 窄的头图（手机竖屏、iPhone Duo 左栏）铺一张 5×5；宽的头图（iPad）左右拼两张，
    /// 只用一张去盖宽幅时每格会大到只剩三四张图，看不出是一面墙。
    private func wall(in size: CGSize) -> some View {
        // 宽窄按墙面本身的高度判断: 顶到上沿多出来的那一截不该让 iPad 换成另一种拼法。
        let isWide = size.width > (size.height - topInset) * 1.9
        let composition: CoverWallComposition
        let geometry: CoverWallGeometry
        if isWide {
            composition = CoverWallLayoutPolicy.stageComposition(
                coverIDs: coverIDs,
                step: step,
                isLandscape: true
            )
            geometry = CoverWallLayoutPolicy.stageGeometry(
                width: Double(size.width),
                height: Double(size.height),
                columns: composition.columns,
                rows: composition.rows
            )
        } else {
            composition = CoverWallLayoutPolicy.composition(
                coverIDs: coverIDs,
                step: step,
                focusID: focusCoverID
            )
            geometry = CoverWallLayoutPolicy.geometry(
                width: Double(size.width),
                height: Double(size.height)
            )
        }
        let planeWidth = CGFloat(geometry.planeLength(cells: composition.columns))
        let planeHeight = CGFloat(geometry.planeLength(cells: composition.rows))
        let hasFocus = composition.tiles.contains(where: \.isFocus)

        return ZStack(alignment: .topLeading) {
            ForEach(composition.tiles) { tile in
                tileView(tile, geometry: geometry, dimmed: hasFocus && !tile.isFocus)
            }
        }
        .frame(width: planeWidth, height: planeHeight, alignment: .topLeading)
        .rotationEffect(.degrees(geometry.rotationDegrees))
        .offset(x: CGFloat(geometry.originX), y: CGFloat(geometry.originY))
        // 同一张封面在两拍之间保持同一个视图身份，所以是「滑过去」而不是一消一现。
        .animation(.easeInOut(duration: 1.4), value: composition)
    }

    private func tileView(
        _ tile: CoverWallTile,
        geometry: CoverWallGeometry,
        dimmed: Bool
    ) -> some View {
        let frame = geometry.frame(of: tile)
        let side = CGFloat(frame.side)
        let centerX = CGFloat(frame.x) + side / 2
        let centerY = CGFloat(frame.y) + side / 2

        return artwork(for: tile.coverID, side: side)
            .frame(width: side, height: side)
            .shadow(color: Color.black.opacity(0.35), radius: 10, y: 6)
            // 有焦点时其余封面退后一步；用透明度与饱和度而不是模糊，十几张图同时模糊太费。
            .opacity(dimmed ? 0.42 : 1)
            .saturation(dimmed ? 0.7 : 1)
            .position(x: centerX, y: centerY)
            .transition(.opacity.combined(with: .scale(scale: 0.92)))
    }

    @ViewBuilder
    private func artwork(for coverID: String, side: CGFloat) -> some View {
        if let song = coverSongs[coverID] {
            CachedArtworkView(
                coverRef: song.coverArtFileName,
                songID: song.id,
                size: side,
                cornerRadius: 12,
                sourceID: song.sourceID,
                filePath: song.filePath,
                fileFormat: song.fileFormat
            )
        } else {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.secondary.opacity(0.18))
        }
    }
}

#endif

/// 封面墙能不能铺得起来。页面先问这里再决定头部用哪种排法；判断规则与
/// `CollectionCoverWallHeader` 内部用的是同一份。开关的键 Mac 也认得（经 iCloud 转发），
/// 所以这一段不限平台。
enum CollectionCoverWall {
    /// 设置 › 资料库显示 里的开关：歌单头图用封面墙还是单张封面。默认开。
    static let preferenceKey = "primuse.library.playlistCoverWall.v1"
    static let defaultEnabled = true

    static func isAvailable(for songs: [Song]) -> Bool {
        CoverWallLayoutPolicy.prefersWall(distinctCoverCount: pool(from: songs, focusGroupKey: nil).count)
    }

    static func pool(
        from songs: [Song],
        focusGroupKey: String?
    ) -> [(candidate: CoverWallCandidate, element: Song)] {
        CoverWallLayoutPolicy.pool(
            from: songs,
            focusGroupKey: focusGroupKey,
            candidate: { song in
                CoverWallCandidate(
                    songID: song.id,
                    groupKey: groupKey(for: song),
                    hasKnownArtwork: !(song.coverArtFileName ?? "").isEmpty
                )
            }
        )
    }

    /// 同一张专辑的歌只占一格；没有专辑信息的歌按封面文件分组，再不行就各算各的。
    static func groupKey(for song: Song) -> String {
        if let albumID = song.albumID, !albumID.isEmpty { return "album:" + albumID }
        if let cover = song.coverArtFileName, !cover.isEmpty { return "cover:" + cover }
        return "song:" + song.id
    }
}
