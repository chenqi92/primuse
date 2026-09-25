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
    @Environment(\.pmHeightClass) private var heightClass
    @Environment(SourceManager.self) private var sourceManager

    @AppStorage(LyricPosterPreferences.styleKey) private var storedStyle = ""
    @AppStorage(LyricPosterPreferences.canvasKey) private var storedCanvas = ""
    @AppStorage(LyricPosterPreferences.prefersMotionKey)
    private var storedPrefersMotion = LyricPosterPreferences.prefersMotionByDefault
    @AppStorage(LyricPosterPreferences.includesTranslationKey)
    private var storedIncludesTranslation = LyricPosterPreferences.includesTranslationByDefault
    @AppStorage(LyricPosterPreferences.showsCreditKey)
    private var storedShowsCredit = LyricPosterPreferences.showsCreditByDefault
    @AppStorage(LyricPosterPreferences.filterKey) private var storedFilter = ""
    @AppStorage(LyricPosterPreferences.motionEffectKey) private var storedMotionEffect = ""
    @AppStorage(LyricPosterPreferences.signatureKey) private var storedSignature = ""
    @AppStorage(LyricPosterPreferences.hasFinishedIntroKey) private var hasFinishedIntro = false

    @State private var isPickingLines = false
    @State private var shareItem: LyricPosterShareItem?
    @State private var errorMessage: String?
    @State private var statusMessage: String?
    @State private var exportTask: Task<Void, Never>?
    @State private var isShareChoicePresented = false
    /// 实况照片被相册拒了、改存了静态图。用来把结果如实说给用户。
    @State private var didFallBackToStill = false
    /// 预览动画的起点。切风格 / 换选句时重置, 让动效从头演一遍。
    @State private var previewEpoch = Date()
    @State private var section: EditorSection = .style
    /// 非 nil 表示正走在引导流程里。
    @State private var wizardStep: LyricPosterWizardStep?

    /// 内容两侧留白, 预览宽度要扣掉。
    private static let contentMargin: CGFloat = 20
    /// 预览最多占这么高, 否则竖版画幅会把风格选择器挤出首屏。
    private static let previewMaximumHeight: CGFloat = 420

    /// 显式初始化。Xcode 27 的 `@State` 改由宏实现，是否还合成逐成员初始化器不再可靠。
    init(composer: LyricPosterComposer) {
        self.composer = composer
    }

    var body: some View {
        NavigationStack {
            // 在 ScrollView 外面量一次可用宽度。垂直 ScrollView 给子视图的高度
            // 提议是 nil, 在里面用 GeometryReader + aspectRatio 反推高度会拿到
            // 10pt 的理想尺寸, 预览框直接塌掉。
            GeometryReader { outer in
                let availableWidth: CGFloat = outer.size.width - Self.contentMargin * 2
                let ceiling: CGFloat = previewCeiling(availableHeight: outer.size.height)
                // 整个界面拆成三段：内容、外壳、状态联动。全串在一条表达式上
                // 时，Swift 的类型检查会直接超时 —— 那在 Xcode 里就是一条
                // "unable to type-check this expression in reasonable time"。
                observing(
                    decorated(
                        content(availableWidth: availableWidth, previewCeiling: ceiling)
                    )
                )
            }
        }
    }

    private func content(availableWidth: CGFloat, previewCeiling: CGFloat) -> some View {
        ScrollView {
            VStack(spacing: 24) {
                preview(availableWidth: availableWidth, previewCeiling: previewCeiling)
                if let wizardStep {
                    wizardBody(step: wizardStep)
                } else {
                    editor
                }
            }
            .padding(.horizontal, Self.contentMargin)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
    }

    /// 标题、工具栏、底部条与各种弹出物。
    private func decorated(_ content: some View) -> some View {
        content
            .navigationTitle(Text("lyric_poster_title"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { toolbarContent }
            .lyricPosterBottomBar {
                if wizardStep == nil {
                    actionBar
                } else {
                    wizardFooter
                }
            }
            .sheet(isPresented: $isPickingLines) {
                LyricPosterLinePicker(composer: composer)
            }
            .sheet(item: $shareItem) { item in
                LyricPosterActivityView(item: item)
            }
            .alert(
                Text("lyric_poster_error_title"),
                isPresented: errorAlertBinding
            ) {
                Button(String(localized: "ok"), role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
    }

    /// 载入、偏好回写与缩略图刷新。
    private func observing(_ content: some View) -> some View {
        content
            .task {
                if !hasFinishedIntro, wizardStep == nil {
                    wizardStep = .lines
                }
                composer.refreshThumbnails(inheritedLayoutDirection: layoutDirection)
                await composer.loadArtwork(sourceManager: sourceManager)
                composer.refreshThumbnails(inheritedLayoutDirection: layoutDirection)
                composer.refreshFilterThumbnails()
            }
            .onChange(of: composer.canvas) { _, newValue in
                storedCanvas = newValue.rawValue
                composer.refreshThumbnails(inheritedLayoutDirection: layoutDirection)
            }
            .onChange(of: composer.filterID) { _, newValue in
                storedFilter = newValue.rawValue
                composer.refreshThumbnails(inheritedLayoutDirection: layoutDirection)
                composer.refreshFilterThumbnails()
            }
            .onChange(of: composer.selection) { _, _ in
                previewEpoch = Date()
                composer.refreshThumbnails(inheritedLayoutDirection: layoutDirection)
            }
            .onChange(of: composer.styleID) { _, newValue in
                storedStyle = newValue.rawValue
                previewEpoch = Date()
            }
            .onDisappear {
                exportTask?.cancel()
            }
    }

    private var errorAlertBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    // MARK: - 预览

    private func preview(availableWidth: CGFloat, previewCeiling: CGFloat) -> some View {
        let size = previewSize(availableWidth: availableWidth, previewCeiling: previewCeiling)

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
    private func previewSize(availableWidth: CGFloat, previewCeiling: CGFloat) -> CGSize {
        let posterWidth = CGFloat(composer.canvas.pixelWidth)
        let posterHeight = CGFloat(composer.canvas.pixelHeight)
        // sheet 刚出现时宽度可能还是 0, 给一个下限免得算出 0 尺寸的预览框。
        let width = max(availableWidth, 120)
        let scale: CGFloat = min(width / posterWidth, previewCeiling / posterHeight)
        return CGSize(width: posterWidth * scale, height: posterHeight * scale)
    }

    /// 手机横屏整页只有三百多点高, 420 的预览会把风格选择器整个挤出首屏 ——
    /// 上面那句注释写的意图在横屏下一直没兑现。这里按可用高度收一档;
    /// 竖屏与 Mac 仍是原来的 420, 导出尺寸不受影响, 变的只是屏幕上的缩放。
    private func previewCeiling(availableHeight: CGFloat) -> CGFloat {
        guard heightClass.isCompact else { return Self.previewMaximumHeight }
        // sheet 刚出现时高度可能还是 0, 给一个下限免得预览框塌成一条线。
        let allowance: CGFloat = max(availableHeight, 240) * 0.55
        return min(Self.previewMaximumHeight, allowance)
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
                let time: TimeInterval = cycle > 0
                    ? elapsed.truncatingRemainder(dividingBy: cycle)
                    : 0
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

    // MARK: - 编辑分区

    /// 设计稿里是右侧那条竖排工具。一屏里放得下的排法是横向分段 + 下面
    /// 换一块面板：改什么都能立刻在上方的预览里看到，不用来回翻页。
    enum EditorSection: String, CaseIterable, Identifiable {
        case style
        case filter
        case effect
        case text

        var id: String { rawValue }

        var titleKey: LocalizedStringKey {
            switch self {
            case .style: return "lyric_poster_section_style"
            case .filter: return "lyric_poster_section_filter"
            case .effect: return "lyric_poster_section_effect"
            case .text: return "lyric_poster_section_text"
            }
        }
    }

    private var availableSections: [EditorSection] {
        EditorSection.allCases.filter { section in
            switch section {
            // 滤镜作用在封面上，没有封面就没有可调的东西。
            case .filter: return composer.hasArtwork
            case .effect: return isMotionCapable
            default: return true
            }
        }
    }

    private var isMotionCapable: Bool {
        #if os(iOS)
        return true
        #else
        return false
        #endif
    }

    private var editor: some View {
        VStack(spacing: 16) {
            Picker("", selection: $section) {
                ForEach(availableSections) { item in
                    Text(item.titleKey).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Group {
                switch section {
                case .style: stylePanel
                case .filter: filterPanel
                case .effect: effectPanel
                case .text: textPanel
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: availableSections) { _, sections in
            if !sections.contains(section), let first = sections.first {
                section = first
            }
        }
    }

    // MARK: 风格

    private var stylePanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(composer.availableDescriptors) { descriptor in
                        styleCard(descriptor)
                    }
                }
                .padding(.horizontal, 2)
                .padding(.vertical, 4)
            }
            .pmStopsAtVerticalBar()

            sectionLabel("lyric_poster_canvas")
            Picker("lyric_poster_canvas", selection: canvasBinding) {
                ForEach(composer.supportedCanvases, id: \.self) { canvas in
                    Text(canvasTitle(canvas)).tag(canvas)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    /// 每种风格现场渲一张小图当按钮 —— 只放图标和名字的话，用户要靠猜
    /// 才知道"杂志"和"信笺"差在哪。
    private func styleCard(_ descriptor: LyricPosterStyleDescriptor) -> some View {
        let isSelected = descriptor.id == composer.styleID
        return Button {
            composer.select(style: descriptor)
        } label: {
            VStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.secondary.opacity(0.12))

                    if let image = composer.thumbnail(for: descriptor.id) {
                        Image(platformImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        Image(systemName: descriptor.symbolName)
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 88, height: 110)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2.5)
                )

                Text(LocalizedStringKey(descriptor.nameKey))
                    .font(.caption2.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .lineLimit(1)
            }
            .frame(width: 88)
        }
        .buttonStyle(.plain)
        .pmAnimation(.hover, value: isSelected)
        .accessibilityLabel(Text(LocalizedStringKey(descriptor.nameKey)))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: 滤镜

    private var filterPanel: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(composer.availableFilters) { spec in
                    filterCard(spec)
                }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 4)
        }
        .pmStopsAtVerticalBar()
    }

    private func filterCard(_ spec: LyricPosterFilterSpec) -> some View {
        let isSelected = spec.id == composer.filterID
        return Button {
            composer.filterID = spec.id
        } label: {
            VStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.secondary.opacity(0.12))
                    if let image = composer.filterThumbnail(for: spec.id) {
                        Image(platformImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    }
                }
                .frame(width: 66, height: 66)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2.5)
                )

                Text(LocalizedStringKey(spec.nameKey))
                    .font(.caption2.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .lineLimit(1)
            }
            .frame(width: 70)
        }
        .buttonStyle(.plain)
        .pmAnimation(.hover, value: isSelected)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: 动效

    private var effectPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("", selection: motionBinding) {
                Text("lyric_poster_output_still").tag(false)
                Text("lyric_poster_output_live").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Text(composer.prefersMotion ? "lyric_poster_motion_footer" : "lyric_poster_still_footer")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if composer.prefersMotion {
                sectionLabel("lyric_poster_section_effect")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(composer.availableMotionEffects) { spec in
                            effectCard(spec)
                        }
                    }
                    .padding(.horizontal, 2)
                    .padding(.vertical, 4)
                }
                .pmStopsAtVerticalBar()
            }
        }
    }

    /// 动效用图标而不是缩略图：一张静止的小图看不出"在动"，画一个会
    /// 骗人。
    private func effectCard(_ spec: LyricPosterMotionEffectSpec) -> some View {
        let isSelected = spec.id == composer.motionEffectID
        return Button {
            composer.motionEffectID = spec.id
            storedMotionEffect = spec.id.rawValue
            previewEpoch = Date()
        } label: {
            VStack(spacing: 6) {
                Image(systemName: spec.symbolName)
                    .font(.title3)
                    .frame(width: 66, height: 52)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.12))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
                    )

                Text(LocalizedStringKey(spec.nameKey))
                    .font(.caption2.weight(isSelected ? .semibold : .regular))
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            .frame(width: 70)
        }
        .buttonStyle(.plain)
        .pmAnimation(.hover, value: isSelected)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var motionBinding: Binding<Bool> {
        Binding(
            get: { composer.prefersMotion },
            set: {
                composer.setPrefersMotion($0)
                storedPrefersMotion = $0
                previewEpoch = Date()
            }
        )
    }

    // MARK: 文字

    private var textPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                sectionLabel("lyric_poster_note")

                ZStack(alignment: .topLeading) {
                    if composer.noteText.isEmpty {
                        Text("lyric_poster_note_placeholder")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 12)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: noteBinding)
                        .font(.callout)
                        .scrollContentBackground(.hidden)
                        .frame(height: 92)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                }
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.secondary.opacity(0.10))
                )

                HStack {
                    TextField("lyric_poster_note_signature", text: signatureBinding)
                        .font(.caption)
                        .textFieldStyle(.plain)
                    Spacer(minLength: 12)
                    Text(verbatim: "\(composer.noteText.count)/\(LyricPosterNotePolicy.maximumLength)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(composer.noteRemaining < 0 ? Color.red : .secondary)
                }
            }

            Divider()

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

            Button {
                isPickingLines = true
            } label: {
                Label(String(localized: "lyric_poster_select_lines"), systemImage: "text.quote")
            }
        }
    }

    private var noteBinding: Binding<String> {
        Binding(
            get: { composer.noteText },
            set: { composer.noteText = String($0.prefix(LyricPosterNotePolicy.maximumLength)) }
        )
    }

    private var signatureBinding: Binding<String> {
        Binding(
            get: { composer.noteSignature },
            set: {
                let trimmed = String($0.prefix(LyricPosterNotePolicy.maximumSignatureLength))
                composer.noteSignature = trimmed
                storedSignature = trimmed
            }
        )
    }

    private func sectionLabel(_ key: LocalizedStringKey) -> some View {
        Text(key)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
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

    // MARK: - 引导流程

    /// 每一步都把预览留在上方：改的是哪一块，看着它变就知道了。
    @ViewBuilder
    private func wizardBody(step: LyricPosterWizardStep) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: step.symbolName)
                    Text(LocalizedStringKey(step.titleKey))
                        .font(.headline)
                    Spacer(minLength: 0)
                    Text(
                        verbatim: "\(LyricPosterWizardPolicy.index(of: step) + 1)/\(LyricPosterWizardPolicy.steps.count)"
                    )
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
                ProgressView(value: LyricPosterWizardPolicy.progress(at: step))
                    .progressViewStyle(.linear)
            }

            switch step {
            case .lines:
                VStack(alignment: .leading, spacing: 10) {
                    LyricPosterLineRows(composer: composer)
                    Text(
                        String(
                            format: String(localized: "lyric_poster_limit_footer"),
                            LyricPosterSelectionPolicy.maximumLines
                        )
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            case .note:
                textPanel
            case .style:
                stylePanel
            case .export:
                if isMotionCapable {
                    effectPanel
                } else {
                    Text("lyric_poster_still_footer")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var wizardFooter: some View {
        HStack(spacing: 12) {
            if let step = wizardStep, let previous = LyricPosterWizardPolicy.previous(before: step) {
                Button {
                    pmWithAnimation(.pageSwitch) { wizardStep = previous }
                } label: {
                    Label(String(localized: "lyric_poster_wizard_back"), systemImage: "chevron.left")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
            } else {
                Button(String(localized: "lyric_poster_wizard_skip")) {
                    finishWizard()
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .frame(maxWidth: .infinity)
            }

            Button {
                advanceWizard()
            } label: {
                Text(
                    wizardStep.map { LyricPosterWizardPolicy.isLast($0) } ?? false
                        ? String(localized: "done")
                        : String(localized: "lyric_poster_wizard_next")
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .disabled(!canAdvanceWizard)
        }
        .controlSize(.large)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var canAdvanceWizard: Bool {
        guard let wizardStep else { return true }
        return LyricPosterWizardPolicy.canAdvance(
            from: wizardStep,
            selectionCount: composer.selection.count
        )
    }

    private func advanceWizard() {
        guard let step = wizardStep else { return }
        if let next = LyricPosterWizardPolicy.next(after: step) {
            pmWithAnimation(.pageSwitch) { wizardStep = next }
        } else {
            finishWizard()
        }
    }

    /// 走完或跳过都落到同一处：引导只是换一种进场方式，状态是同一份，
    /// 退出引导直接接着用单页继续调。
    private func finishWizard() {
        hasFinishedIntro = true
        pmWithAnimation(.pageSwitch) { wizardStep = nil }
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
            if wizardStep == nil {
                Button {
                    wizardStep = .lines
                } label: {
                    Label(String(localized: "lyric_poster_wizard_start"), systemImage: "list.number")
                }
            } else {
                Button(String(localized: "lyric_poster_wizard_skip")) {
                    finishWizard()
                }
            }
        }
    }

    private var actionBar: some View {
        VStack(spacing: 10) {
            // 成对分支: 进度条直接消失、完成提示淡入。两者同时留在这个 VStack
            // 里会把下面的按钮条顶下去再弹回。
            if composer.isExporting {
                ProgressView(value: composer.exportProgress) {
                    Text("lyric_poster_exporting")
                        .font(.caption)
                }
                .progressViewStyle(.linear)
                .pmAppearFade(.control)
            } else if let statusMessage {
                Label(
                    statusMessage,
                    systemImage: didFallBackToStill
                        ? "exclamationmark.circle.fill"
                        : "checkmark.circle.fill"
                )
                .font(.caption)
                .foregroundStyle(didFallBackToStill ? Color.orange : Color.green)
                .multilineTextAlignment(.center)
                .pmAppearFade(.control)
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
        didFallBackToStill = false
        runExport { composer in
            if motion {
                let bundle = try await composer.exportLivePhoto(inheritedLayoutDirection: direction)
                do {
                    try await LyricPosterPhotoLibrary.save(livePhoto: bundle)
                    return .image(bundle.stillURL)
                } catch LyricPosterPhotoLibraryError.saveFailed {
                    // 相册收不收这对资源是它自己说了算的。被拒时用户要的
                    // 仍然是"海报存下来了"，所以退一步存静态图，再如实
                    // 告诉他动的那半没成。
                    didFallBackToStill = true
                }
            }
            let url = try await composer.exportStillImage(inheritedLayoutDirection: direction)
            try await LyricPosterPhotoLibrary.save(image: url)
            return .image(url)
        } completion: { _ in
            statusMessage = String(
                localized: didFallBackToStill ? "lyric_poster_live_fallback" : "lyric_poster_saved"
            )
            Task {
                try? await Task.sleep(nanoseconds: 3_200_000_000)
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
/// 歌词行。弹出的选句页与引导流程的第一步共用这一份，两处的规则才不会
/// 各写一遍。
struct LyricPosterLineRows: View {
    @Bindable var composer: LyricPosterComposer

    var body: some View {
        ForEach(composer.lines) { line in
            row(line)
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
                    ForEach([line.romanization, line.translation].compactMap { $0 }
                        .filter { !$0.isEmpty }, id: \.self) { companion in
                        Text(companion)
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
}

private struct LyricPosterLinePicker: View {
    @Bindable var composer: LyricPosterComposer
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LyricPosterLineRows(composer: composer)
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
