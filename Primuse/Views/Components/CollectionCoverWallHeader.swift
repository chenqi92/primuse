#if os(iOS)
import PrimuseKit
import SwiftUI

/// 集合详情页的「封面墙」头图(`SkinSlotVariant.DetailHeader.coverWall`)。
///
/// 功能契约只有三样:标题、一行摘要、这个集合里的歌。页面上的播放、下载、排序、批量选择
/// 都不经过这里 —— 头图只是头图,换一种画法不会碰到任何功能。
///
/// 封面不够铺一面墙时(少于 `CoverWallLayoutPolicy.minimumDistinctCovers` 张)原样显示
/// 调用方给的 `fallback`,也就是这个页面原来的头部。
struct CollectionCoverWallHeader<Fallback: View>: View {
    private let title: String
    private let subtitle: String
    private let titleSymbol: String?
    private let coverIDs: [String]
    private let coverSongs: [String: Song]
    private let focusCoverID: String?
    private let fallback: Fallback

    @Environment(\.skin) private var skin
    @Environment(\.scenePhase) private var scenePhase
    @State private var step = 0

    /// - Parameters:
    ///   - songs: 集合里的歌,按页面上看到的顺序。只会扫前面一段。
    ///   - nowPlaying: 正在播放的歌。它的封面在这面墙里时会成为焦点。
    init(
        title: String,
        subtitle: String,
        titleSymbol: String? = nil,
        songs: [Song],
        nowPlaying: Song?,
        @ViewBuilder fallback: () -> Fallback
    ) {
        self.title = title
        self.subtitle = subtitle
        self.titleSymbol = titleSymbol
        self.fallback = fallback()

        let focusGroupKey = nowPlaying.map(Self.groupKey(for:))
        let pooled = CoverWallLayoutPolicy.pool(
            from: songs,
            focusGroupKey: focusGroupKey,
            candidate: { song in
                CoverWallCandidate(
                    songID: song.id,
                    groupKey: Self.groupKey(for: song),
                    hasKnownArtwork: !(song.coverArtFileName ?? "").isEmpty
                )
            }
        )
        self.coverIDs = pooled.map(\.candidate.songID)
        self.coverSongs = Dictionary(
            pooled.map { ($0.candidate.songID, $0.element) },
            uniquingKeysWith: { first, _ in first }
        )
        self.focusCoverID = focusGroupKey.flatMap { key in
            pooled.first(where: { $0.candidate.groupKey == key })?.candidate.songID
        }
    }

    /// 同一张专辑的歌只占一格;没有专辑信息的歌按封面文件分组,再不行就各算各的。
    private static func groupKey(for song: Song) -> String {
        if let albumID = song.albumID, !albumID.isEmpty { return "album:" + albumID }
        if let cover = song.coverArtFileName, !cover.isEmpty { return "cover:" + cover }
        return "song:" + song.id
    }

    private var showsWall: Bool {
        CoverWallLayoutPolicy.prefersWall(distinctCoverCount: coverIDs.count)
    }

    /// 离开前台、开启「减弱动态效果」时不换构图。
    private var isCycling: Bool {
        showsWall && !skin.reduceMotion && scenePhase == .active
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
            // 上沿从导航栏下面淡入,下沿融进页面底色:不画硬边,也不需要知道页面底色是什么。
            .mask {
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: 0.16),
                        .init(color: .black, location: 0.44),
                        .init(color: .black.opacity(0.24), location: 0.78),
                        .init(color: .clear, location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .accessibilityHidden(true)

            titleBlock
                .padding(.horizontal, 24)
                .padding(.bottom, 14)
        }
        .frame(height: 320)
        .frame(maxWidth: .infinity)
        .task(id: isCycling) {
            guard isCycling else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(CoverWallLayoutPolicy.reflowInterval))
                if Task.isCancelled { break }
                step += 1
            }
        }
    }

    private var titleBlock: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                if let titleSymbol {
                    Image(systemName: titleSymbol)
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(skin.color(.accent))
                }
                Text(title)
                    .font(skin.font(.pageTitle))
                    .foregroundStyle(.skin(.textPrimary))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            Text(subtitle)
                .font(skin.font(.caption))
                .foregroundStyle(.skin(.textSecondary))
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private func wall(in size: CGSize) -> some View {
        let geometry = CoverWallLayoutPolicy.geometry(
            width: Double(size.width),
            height: Double(size.height)
        )
        let composition = CoverWallLayoutPolicy.composition(
            coverIDs: coverIDs,
            step: step,
            focusID: focusCoverID
        )
        let side = CGFloat(geometry.planeSide(columns: composition.columns))
        let hasFocus = composition.tiles.contains(where: \.isFocus)

        return ZStack(alignment: .topLeading) {
            ForEach(composition.tiles) { tile in
                tileView(tile, geometry: geometry, dimmed: hasFocus && !tile.isFocus)
            }
        }
        .frame(width: side, height: side, alignment: .topLeading)
        .rotationEffect(.degrees(geometry.rotationDegrees))
        .offset(x: CGFloat(geometry.originX), y: CGFloat(geometry.originY))
        // 同一张封面在两拍之间保持同一个视图身份,所以是「滑过去」而不是一消一现。
        .animation(skin.animation(.heroReflow), value: composition)
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
            // 有焦点时其余封面退后一步;用透明度与饱和度而不是模糊,十几张图同时模糊太费。
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
                .fill(skin.color(.surfaceElevated))
        }
    }
}
/// 同一个插槽的单封面画法:专辑这类只有一张封面的集合用它。
/// 居中的封面压在自己放大、模糊之后的光晕上,下沿融进页面底色。
struct CollectionSingleCoverHeader<Artwork: View, Backdrop: View>: View {
    private let title: String
    private let subtitle: String?
    private let caption: String
    private let artwork: Artwork
    private let backdrop: Backdrop

    @Environment(\.skin) private var skin
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    /// - Parameters:
    ///   - artwork: 清晰的那张封面,建议 180 见方。
    ///   - backdrop: 同一张封面的大图,只用来做模糊光晕;「降低透明度」开启时不画。
    init(
        title: String,
        subtitle: String?,
        caption: String,
        @ViewBuilder artwork: () -> Artwork,
        @ViewBuilder backdrop: () -> Backdrop
    ) {
        self.title = title
        self.subtitle = subtitle
        self.caption = caption
        self.artwork = artwork()
        self.backdrop = backdrop()
    }

    var body: some View {
        VStack(spacing: 16) {
            artwork
                .shadow(color: Color.black.opacity(0.4), radius: 24, y: 14)
                .accessibilityHidden(true)

            VStack(spacing: 5) {
                Text(title)
                    .font(skin.font(.pageTitle))
                    .foregroundStyle(.skin(.textPrimary))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(skin.font(.bodyStrong))
                        .foregroundStyle(skin.color(.accent))
                        .multilineTextAlignment(.center)
                }

                Text(caption)
                    .font(skin.font(.caption))
                    .foregroundStyle(.skin(.textSecondary))
                    .multilineTextAlignment(.center)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity)
        .background(alignment: .top) {
            if !reduceTransparency {
                backdrop
                    .blur(radius: 46)
                    .saturation(1.4)
                    .opacity(0.5)
                    .frame(height: 300)
                    .frame(maxWidth: .infinity)
                    .clipped()
                    .mask {
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0),
                                .init(color: .black, location: 0.22),
                                .init(color: .black, location: 0.5),
                                .init(color: .clear, location: 1),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    }
                    .padding(.horizontal, -16)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }
}
#endif
