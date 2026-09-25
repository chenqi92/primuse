#if DEBUG && os(iOS)
import PrimuseKit
import SwiftUI

/// 调试构建的取证页，`PRIMUSE_VISUAL_EVIDENCE=libraryDetail` 启动时替换根视图。
///
/// 手头没有各种尺寸的真机，也没有 iPhone Duo 内屏（iOS 27.1 模拟器只有 Duo，内屏要人在 Device Hub 里拖铰链展开），
/// 就在一台模拟器里按固定尺寸的框渲染真实的页面：框里按那台设备的尺寸等级、安全区与「是不是 iPhone」渲染。
///
/// - `PRIMUSE_EVIDENCE_SET`：
///   - `inner`（默认，Duo 内屏两种推算尺寸下的各页，含分栏的「接下来播放」与桌面半折；跑在 Duo 外屏上）/
///     `phone`（手机横屏的沉浸歌词与播放页）/ `details`（五种详情页在内屏两种尺寸下的两栏）。这三组框里按 iPhone 处理。
///   - `all`（专辑页与艺术家页按各机型视口一屏排开）/ `album` / `artist` / `ax`（无障碍字号那一组）/
///     `dock`（极简的底部停靠条压在专辑页上：竖屏、两种手机横屏、折叠屏内外屏，看宽视口里的限宽，配合 `PRIMUSE_AUTOPLAY_SONG`）。
///     这几组在 iPad 模拟器里跑：上下两条半透明色带标出被导航栏和标签栏 / 迷你条盖住的区域，操作行必须整条落在两条色带之间。
/// - `PRIMUSE_EVIDENCE_ONLY=<n>`：只画这一组里的第 n 个框（从 0 数），放到整屏那么大。
/// - `PRIMUSE_EVIDENCE_ALBUM` / `PRIMUSE_EVIDENCE_ARTIST` / `PRIMUSE_EVIDENCE_PLAYLIST`：标题片段。
///   `inner` / `phone` / `details` 与换尺寸时默认取第一张 / 第一位 / 第一张；其余几组默认 evidence / nova。
/// 播放页的几个框配合 `PRIMUSE_AUTOPLAY_SONG`（`PRIMUSE_AUTOPLAY_PAUSE=1` 定住进度）。
/// - `PRIMUSE_EVIDENCE_MORPH=<页面>`：只画这一页的一个框，每隔 `PRIMUSE_EVIDENCE_MORPH_INTERVAL` 秒（默认 3）在
///   `PRIMUSE_EVIDENCE_MORPH_VIEWPORTS`（默认 `outer,inner`；可选 `outer` `inner` `innerSmall` `innerPortrait`
///   `phone` `phoneLandscape`）之间换一次尺寸，模拟开合、转屏，录屏看换构图的过渡。
struct LibraryDetailEvidenceHost: View {
    @Environment(MusicLibrary.self) private var library
    @Environment(AudioPlayerService.self) private var player
    @State private var homeModel = HomeView.Model()

    private enum Page: String {
        case player, lyrics, immersive, queue, tabletop, home, album, artist, genre, playlist, smart, dock
    }

    fileprivate struct Viewport {
        let name: String
        let size: CGSize
        /// 状态栏那段顶部安全区（导航栏另加）。
        let statusTop: CGFloat
        let leading: CGFloat
        let trailing: CGFloat
        /// 底部安全区。iPad 那几组里是两种外壳里较高的底部遮挡（经典的悬浮标签栏 + 附件迷你条，从屏幕底边量起）。
        let bottom: CGFloat
        /// home 指示条那段底部安全区（停靠条贴在它上面）。
        var homeIndicator: CGFloat = 34
        var isCompactHeight = false
        var isRegularWidth = false
        /// 实测的顶部遮挡(导航栏下沿),与「状态栏 + 导航栏」的推算不一样时写在这里。
        var measuredTop: CGFloat? = nil

        var navigationBar: CGFloat { isCompactHeight ? 78 - statusTop : 54 }
        var top: CGFloat { measuredTop ?? statusTop + navigationBar }

        /// 顶部安全区直接给定(页面自己带导航栏,框只补状态栏那一段)。
        static func fixed(
            name: String,
            size: CGSize,
            top: CGFloat,
            leading: CGFloat,
            trailing: CGFloat,
            bottom: CGFloat,
            isCompactHeight: Bool = false,
            isRegularWidth: Bool = false
        ) -> Viewport {
            Viewport(name: name, size: size, statusTop: top, leading: leading, trailing: trailing, bottom: bottom,
                     homeIndicator: bottom, isCompactHeight: isCompactHeight, isRegularWidth: isRegularWidth,
                     measuredTop: top)
        }
    }

    private struct Frame: Identifiable {
        let page: Page
        let viewport: Viewport
        /// nil:沿用模拟器自己的字号(`simctl ui content_size` 调)。
        var typeSize: DynamicTypeSize? = nil
        var id: String { "\(page.rawValue)-\(viewport.name)-\(typeSize.map { "\($0)" } ?? "system")" }
        var label: String {
            let size = "\(Int(viewport.size.width))×\(Int(viewport.size.height))"
            let type = typeSize.map { $0 == .large ? "" : " · \($0)" } ?? ""
            return "\(page.rawValue) · \(viewport.name) \(size)\(type)"
        }
    }

    // MARK: 视口:iPhone Duo 内屏与手机(`inner` / `phone` / `details` / 换尺寸)

    /// 内屏：官方像素推算的 890×626 与模拟器画面缓冲推算的 951×669 两种都摆上。
    /// 横握时系统竖栏在尾侧（与外屏竖握同侧），顶部没有状态栏那一条；安全区是按实拍截图估的。
    fileprivate static let inner = Viewport.fixed(name: "Duo inner sim", size: CGSize(width: 951, height: 669),
                                                  top: 0, leading: 0, trailing: 84, bottom: 20, isRegularWidth: true)
    fileprivate static let innerSmall = Viewport.fixed(name: "Duo inner", size: CGSize(width: 890, height: 626),
                                                       top: 0, leading: 0, trailing: 84, bottom: 20, isRegularWidth: true)
    fileprivate static let innerPortrait = Viewport.fixed(name: "Duo inner port", size: CGSize(width: 669, height: 951),
                                                          top: 24, leading: 0, trailing: 0, bottom: 20, isRegularWidth: true)
    fileprivate static let outerPortrait = Viewport.fixed(name: "Duo outer", size: CGSize(width: 466, height: 678),
                                                          top: 0, leading: 0, trailing: 84, bottom: 34)
    fileprivate static let phonePortrait = Viewport.fixed(name: "phone", size: CGSize(width: 393, height: 852),
                                                          top: 59, leading: 0, trailing: 0, bottom: 34)
    fileprivate static let phoneLandscape = Viewport.fixed(name: "landscape", size: CGSize(width: 852, height: 393),
                                                           top: 0, leading: 59, trailing: 59, bottom: 21, isCompactHeight: true)
    fileprivate static let seLandscape = Viewport.fixed(name: "SE land", size: CGSize(width: 667, height: 375),
                                                        top: 0, leading: 0, trailing: 0, bottom: 0, isCompactHeight: true)
    fileprivate static let proMaxLandscape = Viewport.fixed(name: "Pro Max land", size: CGSize(width: 956, height: 440),
                                                            top: 0, leading: 62, trailing: 62, bottom: 21,
                                                            isCompactHeight: true, isRegularWidth: true)

    // MARK: 视口:各机型的详情页头图(`all` / `album` / `artist` / `ax` / `dock`)

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
    private let playlistNeedle: String
    private let morphPage: Page?
    private let morphViewports: [Viewport]
    private let morphInterval: Double
    @State private var morphStep = 0

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        let set = environment["PRIMUSE_EVIDENCE_SET"]?.lowercased() ?? "inner"
        let morphPage = environment["PRIMUSE_EVIDENCE_MORPH"].flatMap(Page.init(rawValue:))
        self.set = set
        self.morphPage = morphPage
        morphViewports = (environment["PRIMUSE_EVIDENCE_MORPH_VIEWPORTS"] ?? "outer,inner")
            .split(separator: ",")
            .compactMap { Self.viewport(named: String($0)) }
        morphInterval = environment["PRIMUSE_EVIDENCE_MORPH_INTERVAL"].flatMap(Double.init) ?? 3
        onlyIndex = environment["PRIMUSE_EVIDENCE_ONLY"].flatMap(Int.init)
        // 各机型那几组按「evidence」专辑、「nova」艺术家取证,手机 / 内屏那几组默认取第一张。
        let usesPadSets = Self.padSets.contains(set) && morphPage == nil
        albumNeedle = environment["PRIMUSE_EVIDENCE_ALBUM"]?.lowercased() ?? (usesPadSets ? "evidence" : "")
        artistNeedle = environment["PRIMUSE_EVIDENCE_ARTIST"]?.lowercased() ?? (usesPadSets ? "nova" : "")
        playlistNeedle = environment["PRIMUSE_EVIDENCE_PLAYLIST"]?.lowercased() ?? ""
    }

    /// 在 iPad 模拟器里按各机型视口排开的几组(框里不按 iPhone 处理,画出导航栏与底部遮挡色带)。
    private static let padSets: Set<String> = ["all", "album", "artist", "ax", "dock"]

    /// 这一组框模拟的是 iPhone(Duo 内屏、手机横屏):框里按 iPhone 处理,不带宿主自己的系统竖栏。
    private var simulatesPhoneCanvas: Bool {
        morphPage != nil || !Self.padSets.contains(set)
    }

    private var frames: [Frame] {
        var result: [Frame] = []
        switch set {
        case "details":
            result = [Page.album, .artist, .genre, .playlist, .smart].flatMap { page in
                [Frame(page: page, viewport: Self.inner), Frame(page: page, viewport: Self.innerSmall)]
            }
        case "phone":
            result = [
                Frame(page: .immersive, viewport: Self.phoneLandscape),
                Frame(page: .immersive, viewport: Self.seLandscape),
                Frame(page: .immersive, viewport: Self.proMaxLandscape),
                Frame(page: .player, viewport: Self.phoneLandscape),
                Frame(page: .lyrics, viewport: Self.phoneLandscape),
            ]
        case "all", "album", "artist", "ax":
            if set == "all" || set == "album" {
                result += Self.viewports.map { Frame(page: .album, viewport: $0, typeSize: .large) }
            }
            if set == "all" || set == "artist" {
                result += Self.viewports.map { Frame(page: .artist, viewport: $0, typeSize: .large) }
            }
            if set == "all" || set == "ax" {
                let axViewports = Self.viewports.filter { $0.name == "SE" || $0.name == "Duo cover" }
                for viewport in axViewports {
                    result.append(Frame(page: .album, viewport: viewport, typeSize: .accessibility1))
                    result.append(Frame(page: .artist, viewport: viewport, typeSize: .accessibility1))
                }
            }
        case "dock":
            let names = ["18 Pro", "Duo cover", "Duo cover land", "landscape", "Pro Max land", "Duo inner"]
            result = names.compactMap { name in
                Self.viewports.first { $0.name == name }.map { Frame(page: .dock, viewport: $0, typeSize: .large) }
            }
        default:
            result = [
                Frame(page: .player, viewport: Self.inner),
                Frame(page: .player, viewport: Self.innerSmall),
                Frame(page: .lyrics, viewport: Self.inner),
                Frame(page: .immersive, viewport: Self.inner),
                Frame(page: .immersive, viewport: Self.innerSmall),
                Frame(page: .player, viewport: Self.innerPortrait),
                Frame(page: .home, viewport: Self.inner),
                Frame(page: .album, viewport: Self.inner),
                Frame(page: .album, viewport: Self.innerSmall),
                Frame(page: .artist, viewport: Self.inner),
                Frame(page: .playlist, viewport: Self.inner),
                Frame(page: .smart, viewport: Self.inner),
                Frame(page: .album, viewport: Self.innerPortrait),
                Frame(page: .queue, viewport: Self.inner),
                Frame(page: .tabletop, viewport: Self.innerPortrait),
            ]
        }
        if let onlyIndex {
            return result.indices.contains(onlyIndex) ? [result[onlyIndex]] : []
        }
        return result
    }

    private static func viewport(named name: String) -> Viewport? {
        switch name {
        case "outer": return outerPortrait
        case "inner": return inner
        case "innerSmall": return innerSmall
        case "innerPortrait": return innerPortrait
        case "phone": return phonePortrait
        case "phoneLandscape": return phoneLandscape
        default: return nil
        }
    }

    /// iPad 状态栏那一条留出来，截图里时间不压在第一行框上(只在 iPad 那几组)。
    private var statusBarClearance: CGFloat {
        simulatesPhoneCanvas ? 0 : Self.padStatusBarClearance
    }

    var body: some View {
        let album = library.visibleAlbums.first { albumNeedle.isEmpty || $0.title.lowercased().contains(albumNeedle) }
        let artist = library.visibleArtists.first { artistNeedle.isEmpty || $0.name.lowercased().contains(artistNeedle) }
        GeometryReader { geometry in
            if let album, let artist, let morphPage, morphViewports.count > 1 {
                // 同一个页面、同一个框，只换尺寸：页面自己的视图身份不变，和真机开合、转屏一样。
                let widest = morphViewports.map(\.size.width).max() ?? 1
                let tallest = morphViewports.map(\.size.height).max() ?? 1
                let scale = min(
                    (geometry.size.width - Self.margin * 2) / widest,
                    (geometry.size.height - Self.margin * 2 - Self.labelHeight - 2) / tallest
                )
                let viewport = morphViewports[morphStep % morphViewports.count]
                framed(Frame(page: morphPage, viewport: viewport), scale: scale, album: album, artist: artist)
                    .padding(Self.margin)
                    .task {
                        while !Task.isCancelled {
                            try? await Task.sleep(for: .seconds(morphInterval))
                            morphStep += 1
                        }
                    }
            } else if let album, let artist {
                let frames = frames
                let rows = Self.rows(for: frames, in: geometry.size, topClearance: statusBarClearance)
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
                .padding(.top, statusBarClearance)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // 整页不吃模拟器自己的安全区：框里的页面只能看到下面按视口补上的那一份。
        .ignoresSafeArea()
        .background(Color(white: 0.08).ignoresSafeArea())
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private func framed(_ frame: Frame, scale: CGFloat, album: Album, artist: Artist) -> some View {
        let viewport = frame.viewport
        let size = viewport.size
        let phoneCanvas = simulatesPhoneCanvas
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: frame.label)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(1)
                .frame(width: size.width * scale, alignment: .leading)
            page(frame, album: album, artist: artist)
                .environment(\.pmIsPhoneIdiom, phoneCanvas)
                // 取证页跑在 Duo 外屏上时：框里模拟的是别的视口，不带外屏自己的系统竖栏。
                .environment(\.pmDebugSuppressesVerticalBar, phoneCanvas)
                .environment(\.verticalSizeClass, viewport.isCompactHeight ? .compact : .regular)
                .environment(\.horizontalSizeClass, viewport.isRegularWidth ? .regular : .compact)
                .transformEnvironment(\.dynamicTypeSize) { typeSize in
                    if let fixed = frame.typeSize { typeSize = fixed }
                }
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
                    if !phoneCanvas {
                        chromeBand(height: viewport.top, color: .cyan)
                    }
                }
                .overlay(alignment: .bottom) {
                    // 停靠条那一组要看的是条子本身,不画经典外壳的底部遮挡色带。
                    if frame.page != .dock && !phoneCanvas {
                        chromeBand(height: viewport.bottom, color: .orange)
                    }
                }
                .overlay(alignment: .trailing) {
                    // 系统竖栏的位置（按钮本身由系统画，这里只标出那一条）。
                    if phoneCanvas, viewport.trailing > 0 {
                        Color.cyan.opacity(0.12)
                            .frame(width: viewport.trailing)
                            .allowsHitTesting(false)
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
            if simulatesPhoneCanvas {
                NavigationStack { AlbumDetailView(album: album) }
            } else {
                AlbumDetailView(album: album)
            }
        case .artist:
            if simulatesPhoneCanvas {
                NavigationStack { ArtistDetailView(artist: artist) }
            } else {
                ArtistDetailView(artist: artist)
            }
        case .dock:
            AlbumDetailView(album: album)
        case .genre:
            if let genre = library.visibleGenres.first {
                NavigationStack { DebugGenreDetailEvidencePage(genre: genre) }
            } else {
                Text(verbatim: "no genre")
            }
        case .playlist:
            if let playlist = library.playlists.first(where: {
                playlistNeedle.isEmpty || $0.name.lowercased().contains(playlistNeedle)
            }) {
                NavigationStack { PlaylistDetailView(playlist: playlist) }
            } else {
                Text(verbatim: "no playlist")
            }
        case .smart:
            if let smart = library.smartPlaylists.first {
                NavigationStack { SmartPlaylistDetailView(smartPlaylistID: smart.id) }
            } else {
                Text(verbatim: "no smart playlist")
            }
        case .player, .lyrics, .immersive, .queue, .tabletop:
            // 播放页在外壳里是整屏铺开、自己读窗口安全区的一层，这里照样不吃框的安全区。
            // 桌面半折那一框模拟一道横在屏幕中间的折痕。
            NowPlayingView()
                .environment(\.pmDebugPlayerMode, frame.page.rawValue)
                .environment(\.pmDebugFoldAxis, frame.page == .tabletop ? .horizontal : nil)
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
    private static let padStatusBarClearance: CGFloat = 20
    private static let rowSpacing: CGFloat = 8
    private static let columnSpacing: CGFloat = 8
    private static let labelHeight: CGFloat = 13

    private struct Row {
        var frames: [Frame]
        var scale: CGFloat
    }

    /// 所有框用同一个缩放比例（看得出各视口的真实大小关系），按宽度折行；
    /// 从大往小试比例，取第一个整页放得下的。
    private static func rows(for frames: [Frame], in container: CGSize, topClearance: CGFloat) -> [Row] {
        let width = container.width - margin * 2
        let height = container.height - margin * 2 - topClearance
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

private struct PMDebugPlayerModeKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    /// 取证页让播放页一出现就进入某种模式：`lyrics`（歌词）/ `immersive`（全屏歌词）/ `queue`（接下来播放）。
    var pmDebugPlayerMode: String? {
        get { self[PMDebugPlayerModeKey.self] }
        set { self[PMDebugPlayerModeKey.self] = newValue }
    }
}
#endif
