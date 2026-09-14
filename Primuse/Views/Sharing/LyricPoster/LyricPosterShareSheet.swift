import SwiftUI
import PrimuseKit
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// 歌词海报分享面板: 预览 + 风格/画幅/动静选择 + 导出。
struct LyricPosterShareSheet: View {
    @State var composer: LyricPosterComposer

    @Environment(\.dismiss) private var dismiss
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(SourceManager.self) private var sourceManager

    @AppStorage(LyricPosterPreferences.styleKey) private var storedStyle = ""
    @AppStorage(LyricPosterPreferences.canvasKey) private var storedCanvas = ""
    @AppStorage(LyricPosterPreferences.prefersMotionKey)
    private var storedPrefersMotion = LyricPosterPreferences.prefersMotionByDefault
    @AppStorage(LyricPosterPreferences.includesTranslationKey)
    private var storedIncludesTranslation = LyricPosterPreferences.includesTranslationByDefault
    @AppStorage(LyricPosterPreferences.showsCreditKey)
    private var storedShowsCredit = LyricPosterPreferences.showsCreditByDefault

    @State private var isPickingLines = false
    @State private var shareItem: LyricPosterShareItem?
    @State private var errorMessage: String?
    @State private var statusMessage: String?
    @State private var exportTask: Task<Void, Never>?
    @State private var isShareChoicePresented = false
    /// 预览动画的起点。切风格 / 换选句时重置, 让动效从头演一遍。
    @State private var previewEpoch = Date()

    /// 内容两侧留白, 预览宽度要扣掉。
    private static let contentMargin: CGFloat = 20
    /// 预览最多占这么高, 否则竖版画幅会把风格选择器挤出首屏。
    private static let previewMaximumHeight: CGFloat = 420

    var body: some View {
        NavigationStack {
            // 在 ScrollView 外面量一次可用宽度。垂直 ScrollView 给子视图的高度
            // 提议是 nil, 在里面用 GeometryReader + aspectRatio 反推高度会拿到
            // 10pt 的理想尺寸, 预览框直接塌掉。
            GeometryReader { outer in
                ScrollView {
                    VStack(spacing: 24) {
                        preview(availableWidth: outer.size.width - Self.contentMargin * 2)
                        styleRow
                        canvasRow
                        options
                    }
                    .padding(.horizontal, Self.contentMargin)
                    .padding(.top, 12)
                    .padding(.bottom, 24)
                }
                .navigationTitle(Text("lyric_poster_title"))
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar { toolbarContent }
                .lyricPosterBottomBar { actionBar }
                .sheet(isPresented: $isPickingLines) {
                    LyricPosterLinePicker(composer: composer)
                }
                .sheet(item: $shareItem) { item in
                    LyricPosterActivityView(item: item)
                }
                .alert(
                    Text("lyric_poster_error_title"),
                    isPresented: Binding(
                        get: { errorMessage != nil },
                        set: { if !$0 { errorMessage = nil } }
                    )
                ) {
                    Button(String(localized: "ok"), role: .cancel) { errorMessage = nil }
                } message: {
                    Text(errorMessage ?? "")
                }
                .task {
                    await composer.loadArtwork(sourceManager: sourceManager)
                }
                .onChange(of: composer.styleID) { _, newValue in
                    storedStyle = newValue.rawValue
                    previewEpoch = Date()
                }
                .onChange(of: composer.canvas) { _, newValue in
                    storedCanvas = newValue.rawValue
                }
                .onChange(of: composer.selection) { _, _ in
                    previewEpoch = Date()
                }
                .onDisappear {
                    exportTask?.cancel()
                }
            }
        }
    }

    // MARK: - 预览

    private func preview(availableWidth: CGFloat) -> some View {
        let size = previewSize(availableWidth: availableWidth)

        return VStack(spacing: 12) {
            Group {
                if composer.hasSelection {
                    scaledPoster(in: size)
                } else {
                    emptySelectionPlaceholder
                }
            }
            .frame(width: size.width, height: size.height)
            .frame(maxWidth: .infinity)

            if composer.layoutOverflows {
                Label(
                    String(localized: "lyric_poster_overflow_hint"),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
                .multilineTextAlignment(.center)
            } else if composer.hasSelection {
                Text(
                    String(
                        format: String(localized: "lyric_poster_selection_count"),
                        composer.selection.count
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    /// 预览框的实际尺寸: 先按可用宽度等比缩放, 再受最大高度约束。
    private func previewSize(availableWidth: CGFloat) -> CGSize {
        let posterWidth = CGFloat(composer.canvas.pixelWidth)
        let posterHeight = CGFloat(composer.canvas.pixelHeight)
        // sheet 刚出现时宽度可能还是 0, 给一个下限免得算出 0 尺寸的预览框。
        let width = max(availableWidth, 120)
        let scale: CGFloat = min(width / posterWidth, Self.previewMaximumHeight / posterHeight)
        return CGSize(width: posterWidth * scale, height: posterHeight * scale)
    }

    /// 把 1080 宽的海报整体缩放进预览框。
    ///
    /// 缩放锚点必须和外层 frame 的对齐方式配套: `scaleEffect` 不改变布局尺寸,
    /// 海报仍按 1080×1350 居中摆进预览框(左上角落在框外很远), 这时若用
    /// `.topLeading` 作锚点, 缩放后的画面整个留在可见区域左上方之外, 预览框里
    /// 只剩底色 —— 看上去就是"一片漆黑"。
    private func scaledPoster(in size: CGSize) -> some View {
        let posterWidth = CGFloat(composer.canvas.pixelWidth)
        let posterHeight = CGFloat(composer.canvas.pixelHeight)
        // 宽高都不许越界: 预览框还受 maxHeight 限制, 只按宽度算会在竖版画幅上溢出。
        let widthScale: CGFloat = size.width / posterWidth
        let heightScale: CGFloat = size.height / posterHeight
        let scale: CGFloat = min(widthScale, heightScale)

        return posterContent
            .frame(width: posterWidth, height: posterHeight)
            .scaleEffect(scale)
            // 收到缩放后的真实尺寸上, 圆角和投影才贴着海报边缘。
            .frame(width: posterWidth * scale, height: posterHeight * scale)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: .black.opacity(0.25), radius: 18, y: 8)
    }

    @ViewBuilder
    private var posterContent: some View {
        if isMotionPreview {
            // 20fps 足够演逐句浮现, 而 `.animation` 会按 120Hz 重建整张海报 ——
            // 里面有几处上百点半径的模糊, 按屏幕刷新率重画纯属发热。
            TimelineView(.periodic(from: previewEpoch, by: 1.0 / 20.0)) { timeline in
                let plan = composer.motionPlan
                // 预览循环播放: 一次演完停半秒再来, 跟相册里长按实况的观感一致。
                let elapsed = timeline.date.timeIntervalSince(previewEpoch)
                let cycle = plan.duration + 0.6
                let time = cycle > 0 ? elapsed.truncatingRemainder(dividingBy: cycle) : 0
                composer.preview(
                    at: min(time, plan.duration),
                    isMotion: true,
                    inheritedLayoutDirection: layoutDirection
                )
            }
        } else {
            composer.preview(
                at: 0,
                isMotion: false,
                inheritedLayoutDirection: layoutDirection
            )
        }
    }

    private var emptySelectionPlaceholder: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(.quaternary)
            .overlay {
                VStack(spacing: 10) {
                    Image(systemName: "text.quote")
                        .font(.largeTitle)
                    Text("lyric_poster_empty_selection")
                        .font(.callout)
                }
                .foregroundStyle(.secondary)
            }
    }

    private var isMotionPreview: Bool {
        #if os(iOS)
        composer.prefersMotion && (composer.descriptor?.supportsMotion ?? false)
        #else
        false
        #endif
    }

    // MARK: - 风格 / 画幅

    private var styleRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("lyric_poster_style")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(composer.availableDescriptors) { descriptor in
                        styleChip(descriptor)
                    }
                }
                .padding(.horizontal, 2)
            }
        }
    }

    private func styleChip(_ descriptor: LyricPosterStyleDescriptor) -> some View {
        let isSelected = descriptor.id == composer.styleID
        return Button {
            composer.select(style: descriptor)
        } label: {
            VStack(spacing: 6) {
                Image(systemName: descriptor.symbolName)
                    .font(.title3)
                Text(LocalizedStringKey(descriptor.nameKey))
                    .font(.caption2.weight(.medium))
                    .lineLimit(1)
            }
            .frame(width: 78, height: 66)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(isSelected ? Color.accentColor : .clear, lineWidth: 2)
            )
            .foregroundStyle(isSelected ? Color.accentColor : .primary)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var canvasRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("lyric_poster_canvas")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            Picker("lyric_poster_canvas", selection: canvasBinding) {
                ForEach(composer.supportedCanvases, id: \.self) { canvas in
                    Text(canvasTitle(canvas)).tag(canvas)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    private var canvasBinding: Binding<LyricPosterCanvas> {
        Binding(
            get: { composer.canvas },
            set: { composer.canvas = $0 }
        )
    }

    private func canvasTitle(_ canvas: LyricPosterCanvas) -> LocalizedStringKey {
        switch canvas {
        case .square: return "lyric_poster_canvas_square"
        case .portrait: return "lyric_poster_canvas_portrait"
        case .story: return "lyric_poster_canvas_story"
        }
    }

    // MARK: - 选项

    private var options: some View {
        VStack(spacing: 0) {
            #if os(iOS)
            Toggle(isOn: Binding(
                get: { composer.prefersMotion },
                set: {
                    composer.setPrefersMotion($0)
                    storedPrefersMotion = $0
                    previewEpoch = Date()
                }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("lyric_poster_motion")
                    Text("lyric_poster_motion_footer")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 10)

            Divider()
            #endif

            if composer.hasTranslation {
                Toggle(isOn: Binding(
                    get: { composer.includesTranslation },
                    set: {
                        composer.includesTranslation = $0
                        storedIncludesTranslation = $0
                    }
                )) {
                    Text("lyric_poster_show_translation")
                }
                .padding(.vertical, 10)

                Divider()
            }

            Toggle(isOn: Binding(
                get: { composer.showsCredit },
                set: {
                    composer.showsCredit = $0
                    storedShowsCredit = $0
                }
            )) {
                Text("lyric_poster_show_credit")
            }
            .padding(.vertical, 10)
        }
        .padding(.horizontal, 16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.secondary.opacity(0.08))
        )
    }

    // MARK: - 工具栏与操作条

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button(String(localized: "cancel")) {
                exportTask?.cancel()
                dismiss()
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                isPickingLines = true
            } label: {
                Label(String(localized: "lyric_poster_select_lines"), systemImage: "text.line.first.and.arrowtriangle.forward")
            }
        }
    }

    private var actionBar: some View {
        VStack(spacing: 10) {
            if composer.isExporting {
                ProgressView(value: composer.exportProgress) {
                    Text("lyric_poster_exporting")
                        .font(.caption)
                }
                .progressViewStyle(.linear)
            } else if let statusMessage {
                Label(statusMessage, systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }

            HStack(spacing: 12) {
                #if os(iOS)
                Button {
                    saveToPhotos()
                } label: {
                    actionLabel(String(localized: "lyric_poster_save"), symbol: "square.and.arrow.down")
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                #else
                Button {
                    saveToFile()
                } label: {
                    actionLabel(String(localized: "lyric_poster_save_file"), symbol: "square.and.arrow.down")
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                #endif

                Button {
                    startShare()
                } label: {
                    actionLabel(String(localized: "share"), symbol: "square.and.arrow.up")
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
            }
            .controlSize(.large)
            .disabled(!composer.hasSelection || composer.isExporting)
            .confirmationDialog(
                Text("share"),
                isPresented: $isShareChoicePresented,
                titleVisibility: .hidden
            ) {
                Button(String(localized: "lyric_poster_share_image")) {
                    exportAndShare(motion: false)
                }
                Button(String(localized: "lyric_poster_share_video")) {
                    exportAndShare(motion: true)
                }
                Button(String(localized: "cancel"), role: .cancel) {}
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private func actionLabel(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity)
    }

    // MARK: - 导出动作

    private var canExportMotion: Bool {
        #if os(iOS)
        composer.prefersMotion && (composer.descriptor?.supportsMotion ?? false)
        #else
        false
        #endif
    }

    private func startShare() {
        // 动态海报有两种合理的分享物: 静态图人人都能收, 实况视频才带动效。
        if canExportMotion {
            isShareChoicePresented = true
        } else {
            exportAndShare(motion: false)
        }
    }

    private func exportAndShare(motion: Bool) {
        let direction = layoutDirection
        runExport { composer in
            #if os(iOS)
            if motion {
                let bundle = try await composer.exportLivePhoto(inheritedLayoutDirection: direction)
                return .video(bundle.videoURL)
            }
            #endif
            let url = try await composer.exportStillImage(inheritedLayoutDirection: direction)
            return .image(url)
        } completion: { result in
            shareItem = result
        }
    }

    #if os(iOS)
    private func saveToPhotos() {
        let motion = canExportMotion
        let direction = layoutDirection
        runExport { composer in
            if motion {
                let bundle = try await composer.exportLivePhoto(inheritedLayoutDirection: direction)
                try await LyricPosterPhotoLibrary.save(livePhoto: bundle)
                return .image(bundle.stillURL)
            }
            let url = try await composer.exportStillImage(inheritedLayoutDirection: direction)
            try await LyricPosterPhotoLibrary.save(image: url)
            return .image(url)
        } completion: { _ in
            statusMessage = String(localized: "lyric_poster_saved")
            Task {
                try? await Task.sleep(nanoseconds: 2_400_000_000)
                statusMessage = nil
            }
        }
    }
    #else
    private func saveToFile() {
        let direction = layoutDirection
        runExport { composer in
            .image(try await composer.exportStillImage(inheritedLayoutDirection: direction))
        } completion: { result in
            guard case .image(let url) = result else { return }
            let panel = NSSavePanel()
            panel.nameFieldStringValue = url.lastPathComponent
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let destination = panel.url else { return }
            try? FileManager.default.removeItem(at: destination)
            do {
                try FileManager.default.copyItem(at: url, to: destination)
                statusMessage = String(localized: "lyric_poster_saved_file")
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
    #endif

    /// 导出都走这一条路径: 统一处理取消、错误提示和任务生命周期。
    private func runExport(
        _ work: @escaping @MainActor (LyricPosterComposer) async throws -> LyricPosterShareItem,
        completion: @escaping @MainActor (LyricPosterShareItem) -> Void
    ) {
        exportTask?.cancel()
        statusMessage = nil
        exportTask = Task { @MainActor in
            do {
                let item = try await work(composer)
                guard !Task.isCancelled else { return }
                completion(item)
            } catch is CancellationError {
                // 用户主动取消, 不需要弹错误。
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

// MARK: - 选句

/// 选哪几句。只允许连续的一段 —— 策略层保证, 这里只负责表达。
private struct LyricPosterLinePicker: View {
    @Bindable var composer: LyricPosterComposer
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(composer.lines) { line in
                        row(line)
                    }
                } footer: {
                    Text(
                        String(
                            format: String(localized: "lyric_poster_limit_footer"),
                            LyricPosterSelectionPolicy.maximumLines
                        )
                    )
                }
            }
            .navigationTitle(Text("lyric_poster_select_lines"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "done")) { dismiss() }
                }
            }
            .alert(
                Text(rejectionMessage),
                isPresented: Binding(
                    get: { composer.rejection != nil },
                    set: { if !$0 { composer.rejection = nil } }
                )
            ) {
                Button(String(localized: "ok"), role: .cancel) { composer.rejection = nil }
            }
        }
    }

    private func row(_ line: LyricPosterLine) -> some View {
        let isSelected = composer.isSelected(line.id)
        return Button {
            composer.toggle(line.id)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)

                VStack(alignment: .leading, spacing: 3) {
                    Text(line.text)
                        .foregroundStyle(.primary)
                    if let translation = line.translation, !translation.isEmpty {
                        Text(translation)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .buttonStyle(.plain)
        // 够不着的行留在列表里但压暗: 用户能看懂"只能往两头接", 比直接隐藏好。
        .opacity(isSelected || composer.canExtend(to: line.id) ? 1 : 0.4)
    }

    private var rejectionMessage: LocalizedStringKey {
        switch composer.rejection {
        case .limitReached: return "lyric_poster_limit_reached"
        case .notAdjacent: return "lyric_poster_not_adjacent"
        case nil: return ""
        }
    }
}

// MARK: - 底部操作条

private extension View {
    /// iOS 26 起底部栏用 `safeAreaBar`: 系统自己铺液态玻璃, 内容滚到栏下面时
    /// 边缘会柔化。旧系统没有这个修饰符, 退回 `safeAreaInset` 并自己垫一层
    /// `.bar` —— 否则按钮直接压在内容上。
    @ViewBuilder
    func lyricPosterBottomBar<Bar: View>(@ViewBuilder content: @escaping () -> Bar) -> some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            safeAreaBar(edge: .bottom, spacing: 0, content: content)
                .scrollEdgeEffectStyle(.soft, for: .bottom)
        } else {
            safeAreaInset(edge: .bottom, spacing: 0) {
                content().background(.bar)
            }
        }
        #else
        safeAreaInset(edge: .bottom, spacing: 0) {
            content().background(.bar)
        }
        #endif
    }
}

// MARK: - 分享

enum LyricPosterShareItem: Identifiable {
    case image(URL)
    case video(URL)

    var id: String { url.absoluteString }

    var url: URL {
        switch self {
        case .image(let url), .video(let url): return url
        }
    }
}

#if os(iOS)
/// 系统分享面板。传文件 URL 而不是 UIImage: 接收方能拿到原始 PNG /
/// MOV, 不会被转码成缩略图。
private struct LyricPosterActivityView: UIViewControllerRepresentable {
    let item: LyricPosterShareItem

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [item.url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#else
/// macOS 用 NSSharingServicePicker: 附在一个占位视图上弹出。
private struct LyricPosterActivityView: View {
    let item: LyricPosterShareItem
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SharingPickerAnchor(url: item.url) { dismiss() }
            .frame(width: 1, height: 1)
    }

    private struct SharingPickerAnchor: NSViewRepresentable {
        let url: URL
        let onFinish: () -> Void

        func makeNSView(context: Context) -> NSView {
            let view = NSView()
            DispatchQueue.main.async {
                let picker = NSSharingServicePicker(items: [url])
                picker.show(relativeTo: .zero, of: view, preferredEdge: .minY)
                onFinish()
            }
            return view
        }

        func updateNSView(_ nsView: NSView, context: Context) {}
    }
}
#endif
