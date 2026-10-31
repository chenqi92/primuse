import SwiftUI
import PrimuseKit

/// 电视专辑页左栏下面的「关于这张专辑」、艺人页右栏顶上的「关于这位艺人」。
/// 有简介时像影片介绍页那样是风格、几行摘录和来源,垫一层半透明底;摘录放不下时自己慢慢
/// 往上滚,按下打开全文(全文也能上下翻)。支持手动编辑和 AI 生成,随曲库同步到其他设备。
struct TVLibraryInsightBlock: View {
    @Environment(MusicIntelligenceService.self) private var intelligence
    @Environment(TVStore.self) private var tvStore

    /// 只用名字认出是哪张专辑/哪位艺人;曲目、风格在按下生成时才由 `details` 收集。
    let subject: LibraryInsightSubject
    let details: () -> LibraryInsightSubject
    /// 摘录用掉所在栏剩下的高度(专辑页左栏);否则固定四行。
    var fillsHeight = false

    @State private var showsReader = false
    @State private var showsEditor = false
    @State private var builtInConsent: BuiltInAIConsentRequest?
    @State private var summaryOverflows = false
    @State private var confirmsLastFm = false

    private var store: LibraryInsightStore { .shared }

    private var canAskAI: Bool {
        intelligence.isLibraryInsightAvailable
            || intelligence.libraryInsightNeedsRemoteConsent
            || intelligence.shouldExposeRemoteConfiguration
    }

    var body: some View {
        let insight = store.record(for: subject, in: tvStore.library)
        let showsSynopsis = insight?.hasContent == true
        if LibraryInsightStore.isIntroducible(subject) {
            VStack(alignment: .leading, spacing: 14) {
                if !showsSynopsis {
                    TVEyebrow(text: (subject.kind == .album ? String(localized: "library_insight_album_title") : String(localized: "library_insight_artist_title")))
                }
                TVFocusButton(radius: 18, scale: 1.02, lift: 4, action: { primaryAction(insight) }) { focused in
                    Group {
                        if let insight, showsSynopsis {
                            synopsis(insight, focused: focused)
                                .padding(.horizontal, 22)
                                .padding(.vertical, 20)
                        } else {
                            content(insight)
                                .padding(26)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        Self.background(showsSynopsis: showsSynopsis, focused: focused),
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                    )
                }
                .fullScreenCover(isPresented: $showsReader) {
                    TVLibraryInsightReader(subject: subject)
                        .environment(tvStore)
                }
                .fullScreenCover(isPresented: $showsEditor) {
                    TVLibraryInsightEditor(
                        subject: subject,
                        record: store.record(for: subject, in: tvStore.library),
                        library: tvStore.library
                    )
                }
                .builtInAIConsentSheet($builtInConsent)
                .confirmationDialog(
                    String(localized: "library_insight_lastfm_replace_title"),
                    isPresented: $confirmsLastFm, titleVisibility: .visible
                ) {
                    Button("library_insight_lastfm_fetch", role: .destructive) { fetchLastFm() }
                    Button("cancel", role: .cancel) {}
                } message: {
                    Text("library_insight_lastfm_replace_message")
                }
                .contextMenu {
                    Button("library_insight_edit", systemImage: "pencil") { showsEditor = true }
                        .disabled(store.isGenerating(subject))
                    Button("library_insight_lastfm_fetch", systemImage: "arrow.down.circle") {
                        if showsSynopsis { confirmsLastFm = true } else { fetchLastFm() }
                    }
                    .disabled(store.isGenerating(subject))
                    if let insight, !store.isGenerating(subject) {
                        // 自己写的简介在电视上不给一键覆盖。
                        if !insight.isWorthKeeping, canAskAI {
                            Button {
                                generate()
                            } label: {
                                Label(String(localized: "library_insight_regenerate"), systemImage: "arrow.clockwise")
                            }
                        }
                        Button(role: .destructive) {
                            store.remove(subject, library: tvStore.library)
                        } label: {
                            Label(String(localized: "library_insight_remove"), systemImage: "trash")
                        }
                    }
                }
                if !showsSynopsis, canAskAI {
                    TVPillButton(title: String(localized: "library_insight_edit"), systemImage: "pencil") {
                        showsEditor = true
                    }
                    .disabled(store.isGenerating(subject))
                }
                if !showsSynopsis {
                    TVPillButton(title: String(localized: "library_insight_lastfm_fetch"), systemImage: "arrow.down.circle") {
                        fetchLastFm()
                    }
                    .disabled(store.isGenerating(subject))
                }
            }
            .padding(.bottom, fillsHeight ? 0 : 18)
            #if DEBUG
            .task { await debugSeedIfRequested() }
            #endif
        }
    }

    /// 摘录平时垫一层半透明的页面底色,压在封面取色的底图上也看得清;「生成简介」这类卡片平时
    /// 与曲目行同底;焦点到了都换亮一档的底(与曲目行一致)。卡片原来只多一圈细描边,电视上看不出
    /// 焦点已经从曲目移到了这里。
    private static func background(showsSynopsis: Bool, focused: Bool) -> Color {
        if focused { return TVColor.surfaceStrong }
        return showsSynopsis ? TVColor.bg.opacity(0.38) : TVColor.card
    }

    #if DEBUG
    /// 截图用:`TV_INSIGHT_DEBUG=1` 给打开的专辑 / 艺人写一段示例简介(已有的不覆盖),
    /// `=reader` 另在两秒后打开全文面板。
    private func debugSeedIfRequested() async {
        guard let mode = ProcessInfo.processInfo.environment["TV_INSIGHT_DEBUG"] else { return }
        if store.record(for: subject, in: tvStore.library) == nil {
            store.saveEdit(
                subject,
                summary: """
                    Recorded over one long winter, this album trades the band's early guitar sound for analog synths \
                    and drum machines. The songs move from late-night city drives to quiet bedroom confessions, and \
                    the closing track stretches past nine minutes.

                    Critics at the time were divided, but it has since become the record most fans start with.

                    The sessions took place in a converted warehouse by the harbour. The band set up in a single \
                    room with the tape machine running for whole evenings, and several of the final takes are first \
                    attempts that were never meant to be kept. You can still hear the radiator ticking under the \
                    quietest passages of the second side.

                    A remastered edition added two outtakes and a live recording from the tour that followed. The \
                    live version of the closing track runs almost twelve minutes and ends with the audience singing \
                    the last chorus back to the stage, which the band later said was the moment they knew the record \
                    had found its people.
                    """,
                tags: ["Synth-pop", "New wave", "1980s"],
                aiDraft: nil,
                library: tvStore.library
            )
        }
        guard mode == "reader" else { return }
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        showsReader = true
    }
    #endif

    @ViewBuilder
    private func content(_ insight: LibraryInsightRecord?) -> some View {
        if store.isGenerating(subject) {
            HStack(spacing: 14) {
                ProgressView()
                Text(verbatim: store.progressMessage(for: subject))
                    .tvFont(.body)
                    .foregroundStyle(TVColor.textMuted)
            }
        } else if let message = store.lastFmFailure(for: subject) {
            Text(verbatim: message)
                .tvFont(.body)
                .foregroundStyle(TVColor.textMuted)
        } else if !canAskAI {
            Label(String(localized: "library_insight_edit"), systemImage: "pencil")
                .tvFont(.button)
                .foregroundStyle(TVColor.text)
        } else if let failure = store.failure(for: subject) {
            VStack(alignment: .leading, spacing: 10) {
                Text(verbatim: LibraryInsightStore.message(for: failure))
                    .tvFont(.body)
                    .foregroundStyle(TVColor.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                Text((failure == .needsConsent ? String(localized: "library_insight_allow_and_generate") : String(localized: "library_insight_retry")))
                    .tvFont(.caption, weight: .semibold)
                    .foregroundStyle(TVColor.text)
            }
        } else if let insight {
            VStack(alignment: .leading, spacing: 12) {
                Text((subject.kind == .album ? String(localized: "library_insight_unknown_album") : String(localized: "library_insight_unknown_artist")))
                    .tvFont(.body)
                    .foregroundStyle(TVColor.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                Text(verbatim: LibraryInsightStore.footer(for: insight))
                    .tvFont(.meta)
                    .foregroundStyle(TVColor.textFaint)
                // 按下就重新问一次(换了服务或提示词之后可能就认识了)。
                if canAskAI {
                    Label(String(localized: "library_insight_regenerate"), systemImage: "sparkles")
                        .tvFont(.caption, weight: .semibold)
                        .foregroundStyle(TVColor.text)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text((subject.kind == .album ? String(localized: "library_insight_prompt_album") : String(localized: "library_insight_prompt_artist")))
                    .tvFont(.body)
                    .foregroundStyle(TVColor.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                Label(String(localized: "library_insight_generate"), systemImage: "sparkles")
                    .tvFont(.caption, weight: .semibold)
                    .foregroundStyle(TVColor.text)
            }
        }
    }

    /// 风格一行、四行摘录、来源一行;重新生成中或刚失败时来源那行换成状态。
    private func synopsis(_ insight: LibraryInsightRecord, focused: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if !insight.tags.isEmpty {
                Text(verbatim: insight.tags.joined(separator: " · "))
                    .tvFont(.caption, weight: .semibold)
                    .foregroundStyle(TVColor.textMuted)
                    .lineLimit(1)
            }
            if !insight.summary.isEmpty {
                TVInsightScrollingExcerpt(
                    text: insight.summary,
                    maxLines: fillsHeight ? nil : 4,
                    overflows: $summaryOverflows
                )
            }
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Group {
                    if store.isGenerating(subject) {
                        Text(verbatim: store.progressMessage(for: subject))
                    } else if let message = store.lastFmFailure(for: subject) {
                        Text(verbatim: message)
                    } else if let failure = store.failure(for: subject) {
                        Text(verbatim: LibraryInsightStore.message(for: failure))
                    } else {
                        Text(verbatim: LibraryInsightStore.footer(for: insight))
                    }
                }
                .tvFont(.meta)
                .foregroundStyle(TVColor.textFaint)
                .lineLimit(1)
                Spacer(minLength: 0)
                // 焦点态不增删元素:没截断时只是透明占位。
                Text(String(localized: "more"))
                    .tvFont(.meta, weight: .semibold)
                    .foregroundStyle(focused ? TVColor.text : TVColor.textMuted)
                    .opacity(summaryOverflows ? 1 : 0)
            }
        }
    }

    private func primaryAction(_ insight: LibraryInsightRecord?) {
        if let insight, insight.hasContent {
            showsReader = true
            return
        }
        guard !store.isGenerating(subject) else { return }
        if store.lastFmFailure(for: subject) != nil {
            fetchLastFm()
            return
        }
        guard canAskAI else {
            showsEditor = true
            return
        }
        if let failure = store.failure(for: subject) {
            if failure == .needsConsent, !intelligence.needsBuiltInConsent(for: .libraryInsight) {
                do {
                    try intelligence.grantRemoteConsent()
                } catch {
                    return
                }
            }
            guard store.retryDate(for: subject) == nil else { return }
            generate()
            return
        }
        if canAskAI {
            generate()
        }
    }

    private func generate() {
        // 要交给内置 AI 而还没同意:先弹同意页,同意页会一并打开发送内容的授权。
        if intelligence.needsBuiltInConsent(for: .libraryInsight) {
            builtInConsent = BuiltInAIConsentRequest { generate() }
            return
        }
        let full = details()
        Task { await store.generate(full, library: tvStore.library, intelligence: intelligence) }
    }

    private func fetchLastFm() {
        Task { await store.fetchLastFm(subject, library: tvStore.library) }
    }
}

/// 简介摘录:四行高(或所在栏剩下那么高)的窗口。放得下就静止;放不下时先停 5 秒,再由下往上
/// 慢慢滚到末尾,末尾停 5 秒后淡出、回到开头重来。上下边缘只在有字滚出去 / 还有字没滚上来时才渐隐。
/// 「减弱动态效果」打开时只显示放得下的那几行(按下仍可看全文)。
private struct TVInsightScrollingExcerpt: View {
    let text: String
    /// nil:窗口有多高显示多少行。
    let maxLines: Int?
    @Binding var overflows: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var windowHeight: CGFloat = 0
    @State private var fullHeight: CGFloat = 0
    @State private var offset: CGFloat = 0
    @State private var textOpacity: Double = 1
    @State private var topFade: Double = 0
    @State private var bottomFade: Double = 1

    private static let holdSeconds: Double = 5
    /// 大约两秒多一行,隔着几米也来得及读。
    private static let pointsPerSecond: Double = 18
    private static let fadeHeight: CGFloat = 26
    private static let swapSeconds: Double = 0.5

    private struct Cycle: Equatable {
        let text: String
        let overflow: CGFloat
        let scrolls: Bool
    }

    private var overflow: CGFloat { max(0, (fullHeight - windowHeight).rounded()) }
    private var scrolls: Bool { overflow > 1 && !reduceMotion }

    var body: some View {
        // 限四行的这一份定出窗口大小;要滚时它让位给上面那份全文。
        Text(verbatim: text)
            .tvFont(.body)
            .foregroundStyle(TVColor.text)
            .lineLimit(maxLines)
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(scrolls ? 0 : 1)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { windowHeight = $0 }
            .overlay(alignment: .topLeading) {
                if scrolls {
                    Text(verbatim: text)
                        .tvFont(.body)
                        .foregroundStyle(TVColor.text)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .offset(y: offset)
                        .opacity(textOpacity)
                        // 写明最小高度 0:不写的话框会被全文撑高,下边缘就裁不住。
                        .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
                        .mask(edgeMask)
                        .accessibilityHidden(true)
                }
            }
            .clipped()
            .background(alignment: .topLeading) {
                // 不限行数时有多高:比窗口高才滚、才露出「更多」。
                Text(verbatim: text)
                    .tvFont(.body)
                    .fixedSize(horizontal: false, vertical: true)
                    .hidden()
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fullHeight = $0 }
            }
            .onChange(of: overflow > 1, initial: true) { _, value in overflows = value }
            .task(id: Cycle(text: text, overflow: overflow, scrolls: scrolls)) { await runCycle() }
    }

    private var edgeMask: some View {
        VStack(spacing: 0) {
            LinearGradient(
                colors: [.black.opacity(1 - topFade), .black],
                startPoint: .top, endPoint: .bottom
            )
            .frame(height: Self.fadeHeight)
            Color.black
            LinearGradient(
                colors: [.black, .black.opacity(1 - bottomFade)],
                startPoint: .top, endPoint: .bottom
            )
            .frame(height: Self.fadeHeight)
        }
    }

    private func runCycle() async {
        resetToTop()
        guard scrolls else { return }
        let distance = overflow
        let travel = Double(distance) / Self.pointsPerSecond
        while !Task.isCancelled {
            guard await pause(Self.holdSeconds) else { return }
            withAnimation(.linear(duration: travel)) { offset = -distance }
            withAnimation(.easeInOut(duration: Self.swapSeconds)) { topFade = 1 }
            guard await pause(max(0, travel - Self.swapSeconds)) else { return }
            withAnimation(.easeInOut(duration: Self.swapSeconds)) { bottomFade = 0 }
            guard await pause(Self.swapSeconds + Self.holdSeconds) else { return }
            withAnimation(.easeInOut(duration: Self.swapSeconds)) { textOpacity = 0 }
            guard await pause(Self.swapSeconds) else { return }
            resetToTop(visible: false)
            withAnimation(.easeInOut(duration: Self.swapSeconds)) { textOpacity = 1 }
        }
    }

    private func resetToTop(visible: Bool = true) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            offset = 0
            topFade = 0
            bottomFade = 1
            textOpacity = visible ? 1 : 0
        }
    }

    /// 等一会儿;页面离开或文字变了(任务被取消)→ false。
    private func pause(_ seconds: Double) async -> Bool {
        do {
            try await Task.sleep(for: .seconds(seconds))
            return true
        } catch {
            return false
        }
    }
}

/// 简介全文:居中面板,跟点评编辑同一种弹框。正文一段一段可以选中,方向键往下就往下翻;
/// Menu 或「完成」关掉。
private struct TVLibraryInsightReader: View {
    @Environment(TVStore.self) private var tvStore
    @Environment(\.dismiss) private var dismiss

    let subject: LibraryInsightSubject
    @State private var showsEditor = false
    @State private var showsSource = false

    private var store: LibraryInsightStore { .shared }

    var body: some View {
        let insight = store.record(for: subject, in: tvStore.library)
        ZStack {
            TVAmbientBackdrop(tint: TVColor.brand, tint2: TVColor.brandSecondary, strength: 0.4)
            TVColor.bg.opacity(0.5).ignoresSafeArea()
            card(insight)
                .padding(.horizontal, 90)
                .padding(.vertical, 60)
        }
        .fullScreenCover(isPresented: $showsEditor) {
            TVLibraryInsightEditor(
                subject: subject,
                record: store.record(for: subject, in: tvStore.library),
                library: tvStore.library
            )
        }
        .sheet(isPresented: $showsSource) {
            if let url = insight?.importedURL {
                VStack(spacing: 28) {
                    Text("Last.fm").tvFont(.sectionTitle)
                    TVQRCode(content: url.absoluteString, size: 300)
                    TVPillButton(title: String(localized: "done"), systemImage: "checkmark") { showsSource = false }
                }
                .padding(48)
                .onExitCommand { showsSource = false }
            }
        }
        .onExitCommand { dismiss() }
    }

    private var title: String {
        subject.kind == .album ? subject.albumTitle : subject.artistName
    }

    private func card(_ insight: LibraryInsightRecord?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            TVEyebrow(text: subject.kind == .album
                ? String(localized: "library_insight_album_title")
                : String(localized: "library_insight_artist_title"))
            Text(verbatim: title)
                .tvFont(.pageTitle)
                .foregroundStyle(TVColor.text)
                .lineLimit(2)
                .padding(.top, 10)
            if subject.kind == .album, !subject.artistName.isEmpty {
                Text(verbatim: subject.artistName)
                    .tvFont(.body)
                    .foregroundStyle(TVColor.textMuted)
                    .lineLimit(1)
                    .padding(.top, 6)
            }
            if let insight, !insight.tags.isEmpty {
                Text(verbatim: insight.tags.joined(separator: " · "))
                    .tvFont(.caption, weight: .semibold)
                    .foregroundStyle(TVColor.textMuted)
                    .lineLimit(1)
                    .padding(.top, 14)
            }
            Rectangle().fill(TVColor.divider)
                .frame(height: 1)
                .padding(.top, 26).padding(.bottom, 28)

            if let insight, !insight.summary.isEmpty {
                TVInsightReaderText(text: insight.summary)
            }
            if let insight {
                Group {
                    if insight.importedURL != nil {
                        TVFocusButton(radius: 10, scale: 1.02, lift: 0, action: { showsSource = true }) { focused in
                            Text(verbatim: LibraryInsightStore.footer(for: insight))
                                .padding(8)
                                .background(focused ? TVColor.surfaceStrong : .clear, in: RoundedRectangle(cornerRadius: 10))
                        }
                    } else {
                        Text(verbatim: LibraryInsightStore.footer(for: insight))
                    }
                }
                    .tvFont(.meta)
                    .foregroundStyle(TVColor.textFaint)
                    .padding(.top, 22)
            }

            HStack {
                TVPillButton(title: String(localized: "library_insight_edit"), systemImage: "pencil") {
                    showsEditor = true
                }
                .disabled(store.isGenerating(subject))
                Spacer(minLength: 0)
                TVFocusButton(radius: 14, scale: 1.02, lift: 0, action: { dismiss() }) { focused in
                    Text(String(localized: "done"))
                        .tvFont(.button)
                        .foregroundStyle(TVColor.text)
                        .padding(.horizontal, 30).padding(.vertical, 16)
                        .frame(minWidth: 220)
                        .background(focused ? TVColor.surfaceStrong : TVColor.surfaceSubtle,
                                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
            .padding(.top, 32)
        }
        .padding(.horizontal, 64).padding(.vertical, 52)
        .frame(maxWidth: 1400, alignment: .leading)
        .tvPanel(radius: 26)
    }
}

struct TVLibraryInsightEditor: View {
    @Environment(\.dismiss) private var dismiss
    let subject: LibraryInsightSubject
    let library: MusicLibrary
    @State private var summary: String
    @State private var tagText: String
    @State private var importedDraft: LibraryInsightImportedDraft?
    @State private var fetchMessage: String?

    private var store: LibraryInsightStore { .shared }

    init(subject: LibraryInsightSubject, record: LibraryInsightRecord?, library: MusicLibrary) {
        self.subject = subject
        self.library = library
        _summary = State(initialValue: record?.summary ?? "")
        _tagText = State(initialValue: LibraryInsightEditing.tagText(record?.tags ?? []))
    }

    var body: some View {
        ZStack {
            TVAmbientBackdrop(tint: TVColor.brand, tint2: TVColor.brandSecondary, strength: 0.4)
            TVColor.bg.opacity(0.5).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 24) {
                Text(subject.kind == .album
                    ? String(localized: "library_insight_editor_title_album")
                    : String(localized: "library_insight_editor_title_artist"))
                    .tvFont(.sectionTitle)
                Text(verbatim: subject.kind == .album
                    ? [subject.albumTitle, subject.artistName].filter { !$0.isEmpty }.joined(separator: " · ")
                    : subject.artistName)
                    .tvFont(.body)
                    .foregroundStyle(TVColor.textMuted)
                    .lineLimit(2)
                TVPillButton(title: String(localized: "library_insight_lastfm_fetch"), systemImage: "arrow.down.circle") {
                    Task {
                        fetchMessage = nil
                        if let draft = await store.lastFmDraft(for: subject) {
                            importedDraft = draft
                            summary = draft.summary
                            tagText = LibraryInsightEditing.tagText(draft.tags)
                        } else {
                            fetchMessage = store.lastFmFailure(for: subject)
                            store.clearFailure(for: subject)
                        }
                    }
                }
                .disabled(store.isGenerating(subject))
                if store.isFetchingLastFm(subject) {
                    ProgressView(String(localized: "library_insight_lastfm_fetching"))
                } else if let fetchMessage {
                    Text(verbatim: fetchMessage).tvFont(.caption).foregroundStyle(TVColor.textMuted)
                }
                if !summary.isEmpty {
                    TVInsightReaderText(text: summary)
                        .frame(height: 200)
                }
                TVTextFieldBox {
                    TextField(String(localized: "library_insight_editor_summary"), text: $summary)
                        .accessibilityIdentifier("tv.insight.summary")
                }
                .disabled(store.isGenerating(subject))
                TVTextFieldBox {
                    TextField(String(localized: "library_insight_editor_tags"), text: $tagText)
                        .accessibilityIdentifier("tv.insight.tags")
                }
                .disabled(store.isGenerating(subject))
                HStack(spacing: 18) {
                    TVPillButton(title: String(localized: "save"), systemImage: "checkmark", style: .solid) {
                        guard !store.isGenerating(subject) else { return }
                        store.saveEdit(
                            subject,
                            summary: summary,
                            tags: LibraryInsightEditing.tags(fromText: tagText),
                            aiDraft: nil,
                            importedDraft: importedDraft,
                            library: library
                        )
                        dismiss()
                    }
                    .disabled(store.isGenerating(subject))
                    .accessibilityIdentifier("tv.insight.save")
                    TVPillButton(title: String(localized: "cancel"), systemImage: "xmark") { dismiss() }
                }
            }
            .padding(40)
            .frame(width: 1200, alignment: .leading)
            .tvPanel(radius: 22)
        }
        .onExitCommand { dismiss() }
    }
}

/// 全文正文:按段(太长的段再按句子)拆成几块,每块能获得焦点,滚动视图跟着焦点走,
/// 遥控器按下或往下划就一块一块往下读。自己写的简介可能很长,原来缩小字号也放不下。
/// 同一段里切开的几块挨得近,段与段之间空得多一些,看得出原来的分段。
private struct TVInsightReaderText: View {
    let text: String

    @FocusState private var focusedChunk: Int?

    struct Chunk: Equatable {
        let text: String
        /// 这一块是一段的开头。
        let startsParagraph: Bool
    }

    /// 一块大约这么多字,全文面板上三四行。
    private static let chunkLength = 320

    var body: some View {
        let chunks = Self.chunks(of: text)
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(chunks.indices, id: \.self) { index in
                    let focused = focusedChunk == index
                    Text(verbatim: chunks[index].text)
                        .tvFont(.body)
                        .lineSpacing(6)
                        .foregroundStyle(TVColor.text)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 8)
                        .background(
                            focused ? TVColor.surface : Color.clear,
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                        )
                        .focusable()
                        .focused($focusedChunk, equals: index)
                        .focusEffectDisabled()
                        .animation(.easeOut(duration: 0.18), value: focused)
                        .padding(.top, index > 0 && chunks[index].startsParagraph ? 18 : 0)
                }
            }
            .padding(.vertical, 20)
        }
        .tvScrollEdgeFade()
        .frame(maxHeight: 560)
        .padding(.horizontal, -18)
    }

    /// 按换行分段;一段太长时按句末标点再切,每块不超过 `chunkLength` 太多。
    static func chunks(of text: String) -> [Chunk] {
        let paragraphs = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        var result: [Chunk] = []
        for paragraph in paragraphs {
            guard paragraph.count > chunkLength else {
                result.append(Chunk(text: paragraph, startsParagraph: true))
                continue
            }
            var pieces: [String] = []
            var current = ""
            for sentence in sentences(of: paragraph) {
                if !current.isEmpty, current.count + sentence.count > chunkLength {
                    pieces.append(current.trimmingCharacters(in: .whitespaces))
                    current = ""
                }
                current += sentence
            }
            if !current.trimmingCharacters(in: .whitespaces).isEmpty {
                pieces.append(current.trimmingCharacters(in: .whitespaces))
            }
            for (index, piece) in pieces.enumerated() {
                result.append(Chunk(text: piece, startsParagraph: index == 0))
            }
        }
        return result.isEmpty ? [Chunk(text: text, startsParagraph: true)] : result
    }

    /// 句子连同句末标点和后面的空格一起留着,拼回去和原文一样。全角句号后面直接断;
    /// 半角句号后面要跟着空白才算句末(「3.5」「v1.2」不断开)。
    private static func sentences(of paragraph: String) -> [String] {
        let wideEnders: Set<Character> = ["\u{3002}", "\u{FF01}", "\u{FF1F}", "\u{FF1B}", "\u{2026}"]
        let narrowEnders: Set<Character> = [".", "!", "?", ";"]
        let closers: Set<Character> = ["\u{201D}", "\u{2019}", "\u{300D}", "\u{300F}", ")", "\u{FF09}", "\""]
        var sentences: [String] = []
        var current = ""
        var ended = false
        var narrowPending = false
        for character in paragraph {
            if ended, !character.isWhitespace, !closers.contains(character),
               !wideEnders.contains(character), !narrowEnders.contains(character) {
                sentences.append(current)
                current = ""
                ended = false
            }
            if narrowPending {
                narrowPending = false
                if character.isWhitespace { ended = true }
            }
            current.append(character)
            if wideEnders.contains(character) {
                ended = true
            } else if narrowEnders.contains(character) {
                narrowPending = true
            }
        }
        if !current.isEmpty { sentences.append(current) }
        return sentences
    }
}
