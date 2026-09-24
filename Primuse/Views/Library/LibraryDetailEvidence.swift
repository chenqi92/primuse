#if DEBUG && os(iOS)
import PrimuseKit
import SwiftUI

/// 调试构建的详情页取证页，`PRIMUSE_VISUAL_EVIDENCE=libraryDetail` 启动时替换根视图。
///
/// 手头没有折叠屏和各种尺寸的真机，就在一台 iPad 模拟器里按视口表逐个用固定尺寸的框渲染
/// 真实的专辑页与艺术家页：框里按那台设备的安全区（状态栏 + 导航栏、底部遮挡）留出位置，
/// 上下两条半透明色带标出被导航栏和标签栏 / 迷你条盖住的区域，操作行必须整条落在两条色带之间。
///
/// - `PRIMUSE_EVIDENCE_SET`：`all`（默认，全部一屏排开）/ `album` / `artist` / `ax`（无障碍字号那一组）。
/// - `PRIMUSE_EVIDENCE_ALBUM` / `PRIMUSE_EVIDENCE_ARTIST`：标题片段，默认 evidence / nova。
struct LibraryDetailEvidenceHost: View {
    @Environment(MusicLibrary.self) private var library

    private enum Page: String { case album, artist }

    fileprivate struct Viewport {
        let name: String
        let size: CGSize
        /// 状态栏那段顶部安全区（导航栏另加）。
        let statusTop: CGFloat
        let leading: CGFloat
        let trailing: CGFloat
        /// 底部遮挡：两种外壳里较高的那个（经典的悬浮标签栏 + 附件迷你条，从屏幕底边量起）。
        let bottom: CGFloat
        var isCompactHeight = false
        var isRegularWidth = false

        var navigationBar: CGFloat { isCompactHeight ? 78 - statusTop : 54 }
        var top: CGFloat { statusTop + navigationBar }
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

    /// 点数与安全区：SE / mini / 17e / Pro / Pro Max 按官方规格；折叠屏两块屏按像素与 @3x 推算，安全区是估值。
    fileprivate static let viewports: [Viewport] = [
        Viewport(name: "SE", size: CGSize(width: 375, height: 667), statusTop: 20, leading: 0, trailing: 0, bottom: 139),
        Viewport(name: "13 mini", size: CGSize(width: 375, height: 812), statusTop: 50, leading: 0, trailing: 0, bottom: 147),
        Viewport(name: "17e", size: CGSize(width: 390, height: 844), statusTop: 47, leading: 0, trailing: 0, bottom: 147),
        Viewport(name: "18 Pro", size: CGSize(width: 402, height: 874), statusTop: 62, leading: 0, trailing: 0, bottom: 147),
        Viewport(name: "Pro Max", size: CGSize(width: 440, height: 956), statusTop: 62, leading: 0, trailing: 0, bottom: 147),
        Viewport(name: "Duo cover", size: CGSize(width: 466, height: 678), statusTop: 44, leading: 0, trailing: 0, bottom: 139),
        Viewport(name: "Duo inner", size: CGSize(width: 890, height: 626), statusTop: 24, leading: 0, trailing: 0, bottom: 139,
                 isRegularWidth: true),
        Viewport(name: "landscape", size: CGSize(width: 852, height: 393), statusTop: 0, leading: 59, trailing: 59, bottom: 120,
                 isCompactHeight: true),
        Viewport(name: "iPad", size: CGSize(width: 820, height: 1180), statusTop: 24, leading: 0, trailing: 0, bottom: 139,
                 isRegularWidth: true),
    ]

    private let set: String
    private let albumNeedle: String
    private let artistNeedle: String

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        set = environment["PRIMUSE_EVIDENCE_SET"]?.lowercased() ?? "all"
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
                .overlay(alignment: .top) {
                    chromeBand(height: viewport.top, color: .cyan)
                }
                .overlay(alignment: .bottom) {
                    chromeBand(height: viewport.bottom, color: .orange)
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
        case .album: AlbumDetailView(album: album)
        case .artist: ArtistDetailView(artist: artist)
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
