#if DEBUG && os(iOS)
import PrimuseKit
import SwiftUI

/// 调试构建的详情页取证页，`PRIMUSE_VISUAL_EVIDENCE=libraryDetail` 启动时替换根视图。
///
/// 手头没有折叠屏和各种尺寸的真机，就在一台 iPad 模拟器里按视口表逐个用固定尺寸的框渲染
/// 真实的专辑页与艺术家页：框里按那台设备的安全区（状态栏 + 导航栏、底部遮挡）留出位置，
/// 上下两条半透明色带标出被导航栏和标签栏 / 迷你条盖住的区域，操作行必须整条落在两条色带之间。
///
/// - `PRIMUSE_EVIDENCE_SET`：`all`（默认，全部一屏排开）/ `album` / `artist` / `ax`（无障碍字号那一组）/
///   `dock`（极简的底部停靠条压在专辑页上：竖屏、两种手机横屏、折叠屏内外屏，看宽视口里的限宽，配合 `PRIMUSE_AUTOPLAY_SONG`）/
///   `inner`(Duo 内屏:播放页分栏、竖握单栏、桌面半折,首页与专辑页的两栏;框里按 iPhone 处理,
///   在 iOS 27.1 的 iPad 模拟器里跑才有 `ArrangementView`,配合 `PRIMUSE_AUTOPLAY_SONG`)。
/// - `PRIMUSE_EVIDENCE_ALBUM` / `PRIMUSE_EVIDENCE_ARTIST`：标题片段，默认 evidence / nova。
struct LibraryDetailEvidenceHost: View {
    @Environment(MusicLibrary.self) private var library
    @Environment(AudioPlayerService.self) private var player
    @State private var homeModel = HomeView.Model()

    private enum Page: String { case album, artist, dock, player, tabletop, home }

    fileprivate struct Viewport {
        let name: String
        let size: CGSize
        /// 状态栏那段顶部安全区（导航栏另加）。
        let statusTop: CGFloat
        let leading: CGFloat
        let trailing: CGFloat
        /// 底部遮挡：两种外壳里较高的那个（经典的悬浮标签栏 + 附件迷你条，从屏幕底边量起）。
        let bottom: CGFloat
        /// home 指示条那段底部安全区（停靠条贴在它上面）。
        var homeIndicator: CGFloat = 34
        var isCompactHeight = false
        var isRegularWidth = false
        /// 实测的顶部遮挡(导航栏下沿),与「状态栏 + 导航栏」的推算不一样时写在这里。
        var measuredTop: CGFloat? = nil

        var navigationBar: CGFloat { isCompactHeight ? 78 - statusTop : 54 }
        var top: CGFloat { measuredTop ?? statusTop + navigationBar }
    }

    private struct Frame: Identifiable {
        let page: Page
        let viewport: Viewport
        let typeSize: DynamicTypeSize
        var id: String { "\(page.rawValue)-\(viewport.name)-\(typeSize)" }
        var label: String {
            let size = "\(Int(viewport.size.width))×\(Int(viewport.size.height))"
            let type = typeSize == .large ? "" : " · \(typeSize)"
            return "\(page.rawValue) · \(viewport.name) \(size)\(type)"
        }
    }

    /// 点数与安全区：SE / mini / 17e / Pro / Pro Max 按官方规格。折叠屏外屏按 Duo 模拟器(Xcode 27.1 beta)实测:
    /// 系统把工具栏竖排到侧边,竖握右侧 84、横握左侧 84,顶部安全区 0、底部 34,导航栏仍在顶部 24–82。
    /// 内屏还没实测:官方像素推算的 890×626 与模拟器画面缓冲推算的 951×669 两种都摆上,安全区是估值。
    fileprivate static let viewports: [Viewport] = [
        Viewport(name: "SE", size: CGSize(width: 375, height: 667), statusTop: 20, leading: 0, trailing: 0, bottom: 139),
        Viewport(name: "13 mini", size: CGSize(width: 375, height: 812), statusTop: 50, leading: 0, trailing: 0, bottom: 147),
        Viewport(name: "17e", size: CGSize(width: 390, height: 844), statusTop: 47, leading: 0, trailing: 0, bottom: 147),
        Viewport(name: "18 Pro", size: CGSize(width: 402, height: 874), statusTop: 62, leading: 0, trailing: 0, bottom: 147),
        Viewport(name: "Pro Max", size: CGSize(width: 440, height: 956), statusTop: 62, leading: 0, trailing: 0, bottom: 147),
        Viewport(name: "Duo cover", size: CGSize(width: 466, height: 678), statusTop: 0, leading: 0, trailing: 84, bottom: 139,
                 measuredTop: 82),
        Viewport(name: "Duo cover land", size: CGSize(width: 678, height: 466), statusTop: 0, leading: 84, trailing: 0, bottom: 120,
                 isCompactHeight: true, measuredTop: 82),
        Viewport(name: "Duo inner", size: CGSize(width: 890, height: 626), statusTop: 24, leading: 0, trailing: 0, bottom: 139,
                 homeIndicator: 20, isRegularWidth: true),
        Viewport(name: "Duo inner sim", size: CGSize(width: 951, height: 669), statusTop: 24, leading: 0, trailing: 0, bottom: 139,
                 homeIndicator: 20, isRegularWidth: true),
        Viewport(name: "SE land", size: CGSize(width: 667, height: 375), statusTop: 0, leading: 0, trailing: 0, bottom: 120,
                 homeIndicator: 0, isCompactHeight: true),
        Viewport(name: "landscape", size: CGSize(width: 852, height: 393), statusTop: 0, leading: 59, trailing: 59, bottom: 120,
                 homeIndicator: 21, isCompactHeight: true),
        Viewport(name: "Pro Max land", size: CGSize(width: 956, height: 440), statusTop: 0, leading: 62, trailing: 62, bottom: 120,
                 homeIndicator: 21, isCompactHeight: true),
        Viewport(name: "iPad", size: CGSize(width: 820, height: 1180), statusTop: 24, leading: 0, trailing: 0, bottom: 139,
                 isRegularWidth: true),
    ]

    private let set: String
    /// `PRIMUSE_EVIDENCE_ONLY=<n>`:只画这一组里的第 n 个框(从 0 数),放到整屏那么大。
    private let onlyIndex: Int?
    private let albumNeedle: String
    private let artistNeedle: String

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        set = environment["PRIMUSE_EVIDENCE_SET"]?.lowercased() ?? "all"
        onlyIndex = environment["PRIMUSE_EVIDENCE_ONLY"].flatMap(Int.init)
        albumNeedle = environment["PRIMUSE_EVIDENCE_ALBUM"]?.lowercased() ?? "evidence"
        artistNeedle = environment["PRIMUSE_EVIDENCE_ARTIST"]?.lowercased() ?? "nova"
    }

    private var frames: [Frame] {
        let axViewports = Self.viewports.filter { $0.name == "SE" || $0.name == "Duo cover" }
        var result: [Frame] = []
        if set == "all" || set == "album" {
            result += Self.viewports.map { Frame(page: .album, viewport: $0, typeSize: .large) }
        }
        if set == "all" || set == "artist" {
            result += Self.viewports.map { Frame(page: .artist, viewport: $0, typeSize: .large) }
        }
        if set == "all" || set == "ax" {
            for viewport in axViewports {
                result.append(Frame(page: .album, viewport: viewport, typeSize: .accessibility1))
                result.append(Frame(page: .artist, viewport: viewport, typeSize: .accessibility1))
            }
        }
        if set == "inner" {
            let inner = Self.viewports.first { $0.name == "Duo inner sim" }!
            let innerSmall = Self.viewports.first { $0.name == "Duo inner" }!
            let portrait = Viewport(name: "Duo inner port", size: CGSize(width: 669, height: 951), statusTop: 24,
                                    leading: 0, trailing: 0, bottom: 139, homeIndicator: 20, isRegularWidth: true)
            result += [
                Frame(page: .player, viewport: inner, typeSize: .large),
                Frame(page: .player, viewport: innerSmall, typeSize: .large),
                Frame(page: .player, viewport: portrait, typeSize: .large),
                Frame(page: .tabletop, viewport: portrait, typeSize: .large),
                Frame(page: .home, viewport: inner, typeSize: .large),
                Frame(page: .album, viewport: inner, typeSize: .large),
                Frame(page: .album, viewport: innerSmall, typeSize: .large),
                Frame(page: .artist, viewport: inner, typeSize: .large),
            ]
        }
        if let onlyIndex, set == "inner" {
            return result.indices.contains(onlyIndex) ? [result[onlyIndex]] : []
        }
        if set == "dock" {
            let names = ["18 Pro", "Duo cover", "Duo cover land", "landscape", "Pro Max land", "Duo inner"]
            result += names.compactMap { name in
                Self.viewports.first { $0.name == name }.map { Frame(page: .dock, viewport: $0, typeSize: .large) }
            }
        }
        return result
    }

    var body: some View {
        let album = library.visibleAlbums.first { $0.title.lowercased().contains(albumNeedle) }
        let artist = library.visibleArtists.first { $0.name.lowercased().contains(artistNeedle) }
        GeometryReader { geometry in
            if let album, let artist {
                let frames = frames
                let rows = Self.rows(for: frames, in: geometry.size)
                VStack(alignment: .leading, spacing: Self.rowSpacing) {
                    ForEach(rows.indices, id: \.self) { index in
                        HStack(alignment: .top, spacing: Self.columnSpacing) {
                            ForEach(rows[index].frames) { frame in
                                framed(frame, scale: rows[index].scale, album: album, artist: artist)
                            }
                        }
                    }
                }
                .padding(Self.margin)
                .padding(.top, Self.statusBarClearance)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // 整页不吃 iPad 自己的安全区：框里的详情页只能看到下面按视口表补上的那一份。
        .ignoresSafeArea()
        .background(Color(white: 0.08).ignoresSafeArea())
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private func framed(_ frame: Frame, scale: CGFloat, album: Album, artist: Artist) -> some View {
        let viewport = frame.viewport
        let size = viewport.size
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: frame.label)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(1)
                .frame(width: size.width * scale, alignment: .leading)
            page(frame, album: album, artist: artist)
                .environment(\.pmIsPhoneIdiom, set == "inner")
                // 取证页可能跑在 Duo 外屏上(iOS 27.1 模拟器只有 Duo):框里模拟的是内屏,不带外屏的系统竖栏。
                .environment(\.pmDebugSuppressesVerticalBar, set == "inner")
                .environment(\.pmDebugFoldAxis, frame.page == .tabletop ? .horizontal : nil)
                .environment(\.verticalSizeClass, viewport.isCompactHeight ? .compact : .regular)
                .environment(\.horizontalSizeClass, viewport.isRegularWidth ? .regular : .compact)
                .environment(\.dynamicTypeSize, frame.typeSize)
                .safeAreaPadding(EdgeInsets(
                    top: viewport.top,
                    leading: viewport.leading,
                    bottom: viewport.bottom,
                    trailing: viewport.trailing
                ))
                .frame(width: size.width, height: size.height)
                .overlay(alignment: .bottom) {
                    dockOverlay(frame)
                }
                .overlay(alignment: .top) {
                    if set != "inner" {
                        chromeBand(height: viewport.top, color: .cyan)
                    }
                }
                .overlay(alignment: .bottom) {
                    // 停靠条那一组要看的是条子本身,不画经典外壳的底部遮挡色带;内屏那一组看的是整页版式。
                    if frame.page != .dock && set != "inner" {
                        chromeBand(height: viewport.bottom, color: .orange)
                    }
                }
                .clipped()
                .scaleEffect(scale, anchor: .topLeading)
                .frame(width: size.width * scale, height: size.height * scale, alignment: .topLeading)
                .clipShape(RoundedRectangle(cornerRadius: 6 * scale))
        }
    }

    @ViewBuilder
    private func page(_ frame: Frame, album: Album, artist: Artist) -> some View {
        switch frame.page {
        case .album:
            if set == "inner" {
                NavigationStack { AlbumDetailView(album: album) }
            } else {
                AlbumDetailView(album: album)
            }
        case .artist:
            if set == "inner" {
                NavigationStack { ArtistDetailView(artist: artist) }
            } else {
                ArtistDetailView(artist: artist)
            }
        case .dock: AlbumDetailView(album: album)
        case .player, .tabletop:
            // 播放页在外壳里是整屏铺开、自己读窗口安全区的一层,这里照样不吃框的安全区。
            NowPlayingView()
                .ignoresSafeArea()
        case .home:
            HomeView(model: homeModel, openLibrarySongs: {})
                .environment(homeModel)
        }
    }

    /// 停靠条在外壳里是贴着 home 指示条、左右安全区以内的一层浮层,这里照同样的位置叠在框上。
    @ViewBuilder
    private func dockOverlay(_ frame: Frame) -> some View {
        if frame.page == .dock {
            let viewport = frame.viewport
            DockedPlayerBar(model: NowPlayingBarModel(player: player, library: library, onTap: {}))
                .environment(\.verticalSizeClass, viewport.isCompactHeight ? .compact : .regular)
                .environment(\.horizontalSizeClass, viewport.isRegularWidth ? .regular : .compact)
                .padding(.leading, viewport.leading)
                .padding(.trailing, viewport.trailing)
                .padding(.bottom, viewport.homeIndicator)
        }
    }

    /// 导航栏 / 底部遮挡的位置：半透明色带，边缘一条实线。
    private func chromeBand(height: CGFloat, color: Color) -> some View {
        color.opacity(0.22)
            .overlay(alignment: .center) {
                Rectangle().stroke(color.opacity(0.9), lineWidth: 2)
            }
            .frame(height: height)
            .allowsHitTesting(false)
    }

    // MARK: - 排版：所有框一屏放下

    private static let margin: CGFloat = 10
    /// iPad 状态栏那一条留出来，截图里时间不压在第一行框上。
    private static let statusBarClearance: CGFloat = 20
    private static let rowSpacing: CGFloat = 8
    private static let columnSpacing: CGFloat = 8
    private static let labelHeight: CGFloat = 13

    private struct Row {
        var frames: [Frame]
        var scale: CGFloat
    }

    /// 所有框用同一个缩放比例（看得出各机型的真实大小关系），按宽度折行；
    /// 从大往小试比例，取第一个整页放得下的。
    private static func rows(for frames: [Frame], in container: CGSize) -> [Row] {
        let width = container.width - margin * 2
        let height = container.height - margin * 2 - statusBarClearance
        var scale: CGFloat = 1
        while scale > 0.05 {
            let rows = flow(frames, scale: scale, width: width)
            let total = rows.reduce(CGFloat(0)) { sum, row in
                sum + (row.frames.map(\.viewport.size.height).max() ?? 0) * scale + labelHeight + 2
            } + CGFloat(max(0, rows.count - 1)) * rowSpacing
            if total <= height, !rows.contains(where: { row in
                row.frames.contains { $0.viewport.size.width * scale > width }
            }) {
                return rows
            }
            scale -= 0.005
        }
        return flow(frames, scale: 0.05, width: width)
    }

    private static func flow(_ frames: [Frame], scale: CGFloat, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current: [Frame] = []
        var used: CGFloat = 0
        for frame in frames {
            let frameWidth = frame.viewport.size.width * scale
            if !current.isEmpty, used + columnSpacing + frameWidth > width {
                rows.append(Row(frames: current, scale: scale))
                current = []
                used = 0
            }
            used += (current.isEmpty ? 0 : columnSpacing) + frameWidth
            current.append(frame)
        }
        if !current.isEmpty { rows.append(Row(frames: current, scale: scale)) }
        return rows
    }
}
#endif
