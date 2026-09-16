import SwiftUI
import PrimuseKit

/// 歌词海报的偏好。用户挑过的风格 / 画幅 / 动静下次还在。
enum LyricPosterPreferences {
    static let styleKey = "primuse.lyricPoster.style"
    static let canvasKey = "primuse.lyricPoster.canvas"
    static let prefersMotionKey = "primuse.lyricPoster.prefersMotion"
    static let prefersMotionByDefault = true
    static let includesTranslationKey = "primuse.lyricPoster.includesTranslation"
    static let includesTranslationByDefault = true
    static let showsCreditKey = "primuse.lyricPoster.showsCredit"
    static let showsCreditByDefault = true
}

/// 分享面板的状态机: 持有一份歌词快照, 负责取封面、算配色、渲染和导出。
///
/// 是"快照"而不是"实时绑定": 面板开着的时候用户可能继续听、切歌, 海报上
/// 的内容不该跟着变 —— 用户挑的是刚才那几句。
@MainActor
@Observable
final class LyricPosterComposer: Identifiable {
    /// 每次打开面板都是一份新的快照, 用它驱动 `sheet(item:)`。
    let id = UUID()

    // MARK: 内容

    let songTitle: String
    let artistName: String?
    let albumTitle: String?
    let year: Int?
    let lines: [LyricPosterLine]
    /// 歌词本身的书写方向。阿拉伯语、希伯来语歌词必须右对齐, 否则整张
    /// 海报读起来是反的。
    let writingDirection: LyricWritingDirection

    private(set) var selection: [String]
    /// 最近一次被拒绝的选句操作, UI 用来给出提示后清空。
    var rejection: LyricPosterSelectionRejection?

    // MARK: 外观

    var styleID: LyricPosterStyleID
    var canvas: LyricPosterCanvas
    var prefersMotion: Bool
    var includesTranslation: Bool
    var showsCredit: Bool

    // MARK: 资源

    private(set) var artwork: PlatformImage?
    private(set) var blurredArtwork: PlatformImage?
    private(set) var palette: LyricPosterPalette = .fallback
    private(set) var isLoadingArtwork = false

    // MARK: 导出

    private(set) var isExporting = false
    private(set) var exportProgress: Double = 0

    private let artworkRequest: ArtworkRequest?

    struct ArtworkRequest {
        let coverRef: String?
        let songID: String?
        let sourceID: String?
        let filePath: String?
        let fileFormat: AudioFormat?
    }

    init(
        songTitle: String,
        artistName: String?,
        albumTitle: String?,
        year: Int?,
        lines: [LyricPosterLine],
        selection: [String],
        writingDirection: LyricWritingDirection,
        artworkRequest: ArtworkRequest?,
        styleID: LyricPosterStyleID?,
        canvas: LyricPosterCanvas?,
        prefersMotion: Bool,
        includesTranslation: Bool,
        showsCredit: Bool
    ) {
        self.songTitle = songTitle
        self.artistName = artistName
        self.albumTitle = albumTitle
        self.year = year
        self.lines = lines
        self.selection = selection
        self.writingDirection = writingDirection
        self.artworkRequest = artworkRequest
        self.prefersMotion = prefersMotion
        self.includesTranslation = includesTranslation
        self.showsCredit = showsCredit

        // 封面还没加载完, 先按"无封面"解析风格; 封面到了再放宽一次。
        let resolved = LyricPosterStyleRegistry.shared.resolvedDescriptor(
            preferred: styleID,
            hasArtwork: artworkRequest != nil,
            requiresMotion: prefersMotion
        )
        self.styleID = resolved?.id ?? .gradientQuote
        self.canvas = resolved?.canvas(preferring: canvas) ?? .portrait
    }

    // MARK: - 派生内容

    var content: LyricPosterContent {
        LyricPosterSelectionPolicy.content(
            songTitle: songTitle,
            artistName: artistName,
            albumTitle: albumTitle,
            year: year,
            lines: lines,
            selection: selection
        )
    }

    var hasSelection: Bool { !selection.isEmpty }

    var hasArtwork: Bool { artwork != nil }

    var motionPlan: LyricPosterMotionPlan {
        LyricPosterMotionPolicy.plan(for: content, frameRate: Self.exportFrameRate)
    }

    /// 导出帧率。实况照片的原生素材就是低帧率短片, 24 帧已经很顺,
    /// 再高只是让手机多渲染几十帧。
    static let exportFrameRate = 24

    var descriptor: LyricPosterStyleDescriptor? {
        LyricPosterStyleRegistry.shared.descriptors.first { $0.id == styleID }
    }

    var availableDescriptors: [LyricPosterStyleDescriptor] {
        LyricPosterStyleRegistry.shared.availableDescriptors(
            hasArtwork: hasArtwork,
            requiresMotion: prefersMotion
        )
    }

    var supportedCanvases: [LyricPosterCanvas] {
        descriptor?.supportedCanvases ?? LyricPosterCanvas.allCases
    }

    /// 这段选句里是否真的有译文可显示 —— 没有时"显示翻译"开关不必出现。
    /// Drives the poster's secondary-row switch: a romanization alone is
    /// enough to make it meaningful.
    var hasTranslation: Bool {
        content.hasCompanionText
    }

    /// 当前风格 + 画幅下歌词已经排不进版面。导出的图会被裁, 所以要明说,
    /// 而不是交出一张缺了半句的海报。
    var layoutOverflows: Bool {
        guard hasSelection, let renderer else { return false }
        return renderer.metrics(for: context(at: 0, isMotion: false)).overflows
    }

    // MARK: - 选句

    func toggle(_ id: String) {
        let result = LyricPosterSelectionPolicy.toggling(id, in: lines, selection: selection)
        selection = result.selection
        rejection = result.rejection
    }

    func canExtend(to id: String) -> Bool {
        LyricPosterSelectionPolicy.canExtend(to: id, in: lines, selection: selection)
    }

    func isSelected(_ id: String) -> Bool {
        selection.contains(id)
    }

    // MARK: - 资源加载

    func loadArtwork(sourceManager: SourceManager) async {
        guard let artworkRequest, artwork == nil, !isLoadingArtwork else { return }
        isLoadingArtwork = true
        defer { isLoadingArtwork = false }

        let image = await CachedArtworkView.resolveImage(
            coverRef: artworkRequest.coverRef,
            songID: artworkRequest.songID,
            size: 1024,
            sourceID: artworkRequest.sourceID,
            filePath: artworkRequest.filePath,
            fileFormat: artworkRequest.fileFormat,
            sourceManager: sourceManager
        )
        guard let image else {
            // 封面没取到(源离线、文件里根本没有内嵌图)。依赖封面的风格这时
            // 只会画出一个空壳, 直接换成不需要封面的风格。
            if descriptor?.requiresArtwork == true,
               let fallback = LyricPosterStyleRegistry.shared.resolvedDescriptor(
                   preferred: nil,
                   hasArtwork: false,
                   requiresMotion: prefersMotion
               ) {
                styleID = fallback.id
                canvas = fallback.canvas(preferring: canvas)
            }
            return
        }

        artwork = image
        palette = LyricPosterPalette.make(from: image)
        // 模糊一次就够, 之后每一帧都复用 —— 动态海报有一百多帧, 每帧糊一次
        // 封面是白白多花几秒。
        blurredArtwork = LyricPosterRenderer.blurredArtwork(from: image)

        // 封面到位后, 依赖封面的风格才成为可选项; 用户存过的偏好这时可以兑现。
        if let restored = LyricPosterStyleRegistry.shared.resolvedDescriptor(
            preferred: styleID,
            hasArtwork: true,
            requiresMotion: prefersMotion
        ), restored.id != styleID {
            styleID = restored.id
            canvas = restored.canvas(preferring: canvas)
        }
    }

    /// 换风格时把画幅收敛到该风格支持的范围。
    func select(style: LyricPosterStyleDescriptor) {
        styleID = style.id
        canvas = style.canvas(preferring: canvas)
    }

    /// 切换动静时, 当前风格可能不支持动态。
    func setPrefersMotion(_ value: Bool) {
        prefersMotion = value
        guard value else { return }
        if let resolved = LyricPosterStyleRegistry.shared.resolvedDescriptor(
            preferred: styleID,
            hasArtwork: hasArtwork,
            requiresMotion: true
        ), resolved.id != styleID {
            styleID = resolved.id
            canvas = resolved.canvas(preferring: canvas)
        }
    }

    // MARK: - 渲染

    /// `inherited` 是分享面板所处环境的方向, 用来解析歌词文档里的
    /// `natural`。
    func context(
        at time: TimeInterval,
        isMotion: Bool,
        inheritedLayoutDirection: LayoutDirection = .leftToRight
    ) -> LyricPosterRenderContext {
        let plan = motionPlan
        return LyricPosterRenderContext(
            content: content,
            canvas: canvas,
            palette: palette,
            artwork: artwork,
            blurredArtwork: blurredArtwork,
            motion: plan,
            time: isMotion ? time : plan.duration,
            isMotion: isMotion,
            includesTranslation: includesTranslation,
            showsCredit: showsCredit,
            layoutDirection: resolvedLayoutDirection(inheritedLayoutDirection),
            appName: Self.appName
        )
    }

    private func resolvedLayoutDirection(_ inherited: LayoutDirection) -> LayoutDirection {
        switch writingDirection {
        case .leftToRight: return .leftToRight
        case .rightToLeft: return .rightToLeft
        case .natural: return inherited
        }
    }

    var renderer: (any LyricPosterStyleRendering)? {
        LyricPosterStyleRegistry.shared.renderer(for: styleID)
    }

    @ViewBuilder
    func preview(
        at time: TimeInterval,
        isMotion: Bool,
        inheritedLayoutDirection: LayoutDirection
    ) -> some View {
        if let renderer {
            LyricPosterRenderer.makeView(
                style: renderer,
                context: context(
                    at: time,
                    isMotion: isMotion,
                    inheritedLayoutDirection: inheritedLayoutDirection
                )
            )
        } else {
            Color.black
        }
    }

    // MARK: - 导出

    enum ExportError: LocalizedError {
        case noRenderer
        case renderFailed

        var errorDescription: String? {
            switch self {
            case .noRenderer, .renderFailed:
                return String(localized: "lyric_poster_error_render")
            }
        }
    }

    /// 静态海报 PNG。渐变面积大, PNG 不会在色带边缘糊成块。
    func exportStillImage(inheritedLayoutDirection: LayoutDirection) async throws -> URL {
        guard let renderer else { throw ExportError.noRenderer }
        isExporting = true
        exportProgress = 0
        defer {
            isExporting = false
            exportProgress = 0
        }

        let context = context(
            at: 0,
            isMotion: false,
            inheritedLayoutDirection: inheritedLayoutDirection
        )
        guard let image = LyricPosterRenderer.renderImage(style: renderer, context: context),
              let data = LyricPosterRenderer.pngData(from: image) else {
            throw ExportError.renderFailed
        }
        exportProgress = 1

        let url = try makeExportDirectory().appendingPathComponent("\(exportBaseName).png")
        try data.write(to: url, options: .atomic)
        return url
    }

    #if os(iOS)
    /// 实况照片。静图和视频写在同一个目录, 存相册时必须一起提交。
    func exportLivePhoto(
        inheritedLayoutDirection: LayoutDirection
    ) async throws -> LyricPosterLivePhotoBundle {
        guard let renderer else { throw ExportError.noRenderer }
        isExporting = true
        exportProgress = 0
        defer {
            isExporting = false
            exportProgress = 0
        }

        let plan = motionPlan
        let directory = try makeExportDirectory()
        let size = CGSize(width: canvas.pixelWidth, height: canvas.pixelHeight)

        return try await LyricPosterLivePhotoWriter.write(
            plan: plan,
            size: size,
            directory: directory,
            baseName: exportBaseName,
            frame: { [weak self] index in
                guard let self else { return nil }
                let frameContext = self.context(
                    at: plan.time(ofFrame: index),
                    isMotion: true,
                    inheritedLayoutDirection: inheritedLayoutDirection
                )
                return LyricPosterRenderer.renderCGImage(style: renderer, context: frameContext)
            },
            onProgress: { [weak self] progress in
                self?.exportProgress = progress
            }
        )
    }
    #endif

    // MARK: - 临时文件

    /// 导出物放系统临时目录: 分享和存相册都只需要它活到那一刻, 系统回收
    /// 也不会带走用户的东西。
    private func makeExportDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LyricPosters", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private var exportBaseName: String {
        let raw = [songTitle, artistName].compactMap { $0 }.joined(separator: "-")
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let sanitized = raw.unicodeScalars
            .map { allowed.contains($0) ? Character($0) : "_" }
            .prefix(48)
        let stamp = Int(Date().timeIntervalSince1970)
        return "\(String(sanitized))-\(stamp)"
    }

    private static var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "Primuse"
    }
}

// MARK: - 从播放中的歌曲构造

extension LyricPosterComposer {
    /// 播放页入口。`anchorLineID` 是长按选中的那一句; 没有时按当前播放位置定位。
    static func make(
        song: Song,
        lyrics: [LyricLine],
        translations: [String: String],
        playbackPosition: TimeInterval,
        anchorLineID: String?,
        writingDirection: LyricWritingDirection,
        styleID: LyricPosterStyleID?,
        canvas: LyricPosterCanvas?,
        prefersMotion: Bool,
        includesTranslation: Bool,
        showsCredit: Bool
    ) -> LyricPosterComposer {
        let lines = LyricPosterSelectionPolicy.selectableLines(
            from: lyrics,
            translations: translations
        )
        let selection: [String]
        if let anchorLineID, lines.contains(where: { $0.id == anchorLineID }) {
            selection = [anchorLineID]
        } else {
            selection = LyricPosterSelectionPolicy.defaultSelection(
                in: lines,
                playbackPosition: playbackPosition
            )
        }

        return LyricPosterComposer(
            songTitle: song.title,
            artistName: song.artistName,
            albumTitle: song.albumTitle,
            year: song.year,
            lines: lines,
            selection: selection,
            writingDirection: writingDirection,
            artworkRequest: ArtworkRequest(
                coverRef: song.coverArtFileName,
                songID: song.id,
                sourceID: song.sourceID,
                filePath: song.filePath,
                fileFormat: song.fileFormat
            ),
            styleID: styleID,
            canvas: canvas,
            prefersMotion: prefersMotion,
            includesTranslation: includesTranslation,
            showsCredit: showsCredit
        )
    }
}
