import SwiftUI
import PrimuseKit

/// 简介的几样操作:让 AI 生成、写回音乐源、删除、读回音乐源已有的。
/// 头图里的摘录和全文页共用,逻辑只有一份。
@MainActor
struct LibraryInsightActions {
    /// 只用名字认出是哪张专辑/哪位艺人;曲目、风格等在要问 AI 时才由 `details` 收集。
    let subject: LibraryInsightSubject
    let details: () -> LibraryInsightSubject
    /// 这张专辑 / 这位艺人在曲库里的歌:写回音乐源、从音乐源读简介时用。
    let songs: () -> [Song]
    let library: MusicLibrary
    let intelligence: MusicIntelligenceService
    let sourceManager: SourceManager
    let sourcesStore: SourcesStore

    private var store: LibraryInsightStore { .shared }

    var canAskAI: Bool {
        intelligence.isLibraryInsightAvailable
            || intelligence.libraryInsightNeedsRemoteConsent
            || intelligence.shouldExposeRemoteConfiguration
    }

    func generate() {
        let full = details()
        Task {
            await store.generate(full, library: library, intelligence: intelligence)
            if store.failure(for: subject) == nil { writeBack() }
        }
    }

    func grantConsentAndGenerate() {
        do {
            try intelligence.grantRemoteConsent()
            generate()
        } catch {
            store.clearFailure(for: subject)
        }
    }

    func remove() {
        store.remove(subject, library: library)
        writeBack()
    }

    /// 存下来的简介按各音乐源能写的方式写出去,结果显示在全文页底部。
    func writeBack() {
        let subject = subject
        let songs = songs()
        Task {
            let record = library.storedLibraryInsightRecord(id: store.recordID(for: subject))
            let report = await LibraryInsightWriteback.write(
                record,
                subject: subject,
                songs: songs,
                library: library,
                sourceManager: sourceManager,
                sourcesStore: sourcesStore
            )
            store.setWritebackNote(written: report.written, failed: report.failed, for: subject)
        }
    }

    /// 曲库里还没有记录(也没有墓碑)时,读回 album.nfo 或媒体服务器上已有的简介。
    func importIfAvailable() async {
        guard store.record(for: subject, in: library) == nil else { return }
        await LibraryInsightWriteback.importIfAvailable(
            subject: subject,
            songs: songs(),
            library: library,
            sourceManager: sourceManager,
            sourcesStore: sourcesStore
        )
    }
}

/// 详情页头图里的简介,照影片介绍页的摆法:风格一行、几行摘录、来源一行,点开读全文。
/// 白字压在详情页的深色头图上(iPhone、iPad、Mac 都是)。还没有简介时只占一颗
/// 「添加简介」小胶囊;生成中、失败、AI 不认识时就地显示 —— 页尾不再另放一张卡片,
/// 让 AI 写完不用滚回顶上找。
struct LibraryInsightSynopsis: View {
    @Environment(MusicIntelligenceService.self) private var intelligence
    @Environment(MusicLibrary.self) private var library
    @Environment(SourceManager.self) private var sourceManager
    @Environment(SourcesStore.self) private var sourcesStore

    let subject: LibraryInsightSubject
    let details: () -> LibraryInsightSubject
    let songs: () -> [Song]
    /// 矮头图(手机横屏):头图是一条矮的信息带,简介收成一行,首屏才露得出歌。
    /// 位置不随横竖屏换 —— 这里挂着菜单和弹页,换宿主会把它们一起拆掉。
    var compact = false

    @State private var showsReader = false
    @State private var isEditing = false
    @State private var confirmsRegenerate = false
    @State private var excerptHeight: CGFloat = 0
    @State private var fullHeight: CGFloat = 0

    private var store: LibraryInsightStore { .shared }

    private var actions: LibraryInsightActions {
        LibraryInsightActions(
            subject: subject,
            details: details,
            songs: songs,
            library: library,
            intelligence: intelligence,
            sourceManager: sourceManager,
            sourcesStore: sourcesStore
        )
    }

    #if os(macOS)
    private let summaryFont = Font.system(size: 13)
    private let metaFont = Font.system(size: 11)
    private let tagFont = Font.system(size: 11.5, weight: .semibold)
    private let chipFont = Font.system(size: 12, weight: .semibold)
    #else
    private let summaryFont = Font.subheadline
    private let metaFont = Font.caption2
    private let tagFont = Font.caption.weight(.semibold)
    private let chipFont = Font.footnote.weight(.semibold)
    #endif

    #if DEBUG
    /// 截图钩子:`PRIMUSE_DEBUG_INSIGHT_EDIT=1` 让首个出现的简介打开编辑页,`=reader` 打开全文页,只开一次
    /// (配合 `PRIMUSE_OPEN_PAGE=artist:<名字>` 看染色详情页里弹出的页面)。
    @MainActor private static var didOpenDebugEditor = false

    private func openDebugEditorIfRequested() async {
        let mode = ProcessInfo.processInfo.environment["PRIMUSE_DEBUG_INSIGHT_EDIT"]
        guard !Self.didOpenDebugEditor, mode == "1" || mode == "reader" else { return }
        Self.didOpenDebugEditor = true
        try? await Task.sleep(for: .seconds(3))
        guard !Task.isCancelled else { return }
        plog("🧪 Debug: open insight \(mode == "reader" ? "reader" : "editor")")
        if mode == "reader" {
            showsReader = true
        } else {
            isEditing = true
        }
    }
    #endif

    var body: some View {
        if LibraryInsightStore.isIntroducible(subject) {
            let record = store.record(for: subject, in: library)
            Group {
                if let record, record.hasContent {
                    excerpt(record)
                } else {
                    status(record)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // 头图恒为深底白字,转圈、菜单这些系统控件也按深色画。
            .environment(\.colorScheme, .dark)
            .pmAnimation(.control, value: store.isGenerating(subject))
            // 弹出的全文页、编辑页挂在透明宿主上:头图在染色详情页里是深色外观,
            // 弹出页要在宿主外层换回 App 本来的外观,否则浅色模式下会白底白字。
            .background {
                Color.clear
                    .sheet(isPresented: $showsReader) {
                        LibraryInsightReaderSheet(actions: actions)
                    }
                    .sheet(isPresented: $isEditing) {
                        LibraryInsightEditorSheet(subject: subject, details: details, record: record) {
                            actions.writeBack()
                        }
                    }
                    .confirmationDialog(
                        Text("library_insight_regenerate_confirm_title"),
                        isPresented: $confirmsRegenerate,
                        titleVisibility: .visible
                    ) {
                        Button("library_insight_regenerate_confirm_action", role: .destructive) { actions.generate() }
                        Button("cancel", role: .cancel) {}
                    } message: {
                        Text("library_insight_regenerate_confirm_message")
                    }
                    .libraryDetailPresentationReset()
            }
            #if DEBUG
            .task { await openDebugEditorIfRequested() }
            #endif
            .task(id: store.recordID(for: subject)) {
                await actions.importIfAvailable()
            }
        }
    }

    // MARK: 有简介

    private func excerpt(_ record: LibraryInsightRecord) -> some View {
        Button {
            showsReader = true
        } label: {
            if compact {
                compactExcerpt(record)
            } else {
                fullExcerpt(record)
            }
        }
        .buttonStyle(.plain)
        .contextMenu { menuItems(record) }
    }

    private func fullExcerpt(_ record: LibraryInsightRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if !record.tags.isEmpty {
                Text(verbatim: record.tags.joined(separator: " \u{00B7} "))
                    .font(tagFont)
                    .foregroundStyle(.white.opacity(0.74))
                    .lineLimit(1)
            }
            if !record.summary.isEmpty {
                summaryText(record.summary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                sourceLine(record)
                Spacer(minLength: 8)
                if fullHeight > excerptHeight + 1 {
                    Text("more")
                        .font(tagFont)
                        .foregroundStyle(.white)
                }
            }
        }
        .multilineTextAlignment(.leading)
        .contentShape(Rectangle())
    }

    /// 一行:AI 写的带个星标(来源那行收掉了,标记不能跟着丢),摘录,「更多」。
    private func compactExcerpt(_ record: LibraryInsightRecord) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if !record.isUserEdited, record.importedFrom == nil, record.aiProviderName != nil {
                Image(systemName: "sparkles")
                    .font(metaFont)
                    .foregroundStyle(.white.opacity(0.7))
                    .accessibilityLabel(Text(verbatim: LibraryInsightStore.footer(for: record)))
            }
            Text(verbatim: record.summary.isEmpty
                ? record.tags.joined(separator: " \u{00B7} ")
                : record.summary.replacingOccurrences(of: "\n", with: " "))
                .font(summaryFont)
                .foregroundStyle(.white.opacity(0.88))
                .lineLimit(1)
            Spacer(minLength: 8)
            if store.isGenerating(subject) {
                ProgressView().controlSize(.mini)
            }
            Text("more")
                .font(tagFont)
                .foregroundStyle(.white)
        }
        .contentShape(Rectangle())
    }

    private func summaryText(_ summary: String) -> some View {
        Text(verbatim: summary)
            .font(summaryFont)
            .lineSpacing(2)
            .foregroundStyle(.white.opacity(0.88))
            .lineLimit(3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { excerptHeight = $0 }
            .background(alignment: .topLeading) {
                // 不限行数时有多高:比摘录高才露出「更多」。
                Text(verbatim: summary)
                    .font(summaryFont)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .hidden()
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fullHeight = $0 }
            }
    }

    /// 摘录下面那一行:平时是来源(AI 生成 · 服务 · 可能有误 / 已编辑 / 来自 album.nfo),
    /// 重新生成中、刚失败时换成状态。
    @ViewBuilder
    private func sourceLine(_ record: LibraryInsightRecord) -> some View {
        if store.isGenerating(subject) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("library_insight_generating")
            }
            .font(metaFont)
            .foregroundStyle(.white.opacity(0.72))
        } else if let failure = store.failure(for: subject) {
            Text(verbatim: LibraryInsightStore.message(for: failure))
                .font(metaFont)
                .foregroundStyle(.white.opacity(0.72))
                .lineLimit(1)
        } else {
            Text(verbatim: LibraryInsightStore.footer(for: record))
                .font(metaFont)
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private func menuItems(_ record: LibraryInsightRecord) -> some View {
        Button {
            isEditing = true
        } label: {
            Label("library_insight_edit", systemImage: "pencil")
        }
        if actions.canAskAI {
            Button {
                if record.isWorthKeeping {
                    confirmsRegenerate = true
                } else {
                    actions.generate()
                }
            } label: {
                Label("library_insight_regenerate", systemImage: "sparkles")
            }
            .disabled(store.isGenerating(subject) || store.retryDate(for: subject) != nil)
        }
        Divider()
        Button(role: .destructive) {
            actions.remove()
        } label: {
            Label("library_insight_remove", systemImage: "trash")
        }
    }

    // MARK: 还没有简介

    @ViewBuilder
    private func status(_ record: LibraryInsightRecord?) -> some View {
        if store.isGenerating(subject) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("library_insight_generating")
                    .font(chipFont)
                    .foregroundStyle(.white.opacity(0.78))
            }
        } else if let failure = store.failure(for: subject) {
            noteAndActions(Text(verbatim: LibraryInsightStore.message(for: failure))) {
                failureAction(failure)
                chip("library_insight_write_own", systemImage: "pencil") {
                    store.clearFailure(for: subject)
                    isEditing = true
                }
            }
        } else if let record, record.aiKnown == false {
            noteAndActions(Text(subject.kind == .album
                ? LocalizedStringKey("library_insight_unknown_album")
                : LocalizedStringKey("library_insight_unknown_artist"))) {
                // 换了服务或改了提示词之后,原来说不认识的可能认识了。
                if actions.canAskAI {
                    chip("library_insight_regenerate", systemImage: "sparkles") { actions.generate() }
                        .disabled(store.retryDate(for: subject) != nil)
                }
                chip("library_insight_write_own", systemImage: "pencil") { isEditing = true }
            }
        } else if actions.canAskAI {
            Menu {
                Button {
                    actions.generate()
                } label: {
                    Label("library_insight_generate", systemImage: "sparkles")
                }
                Button {
                    isEditing = true
                } label: {
                    Label("library_insight_write_own", systemImage: "pencil")
                }
            } label: {
                chipLabel("library_insight_add", systemImage: "text.badge.plus")
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
        } else {
            chip("library_insight_add", systemImage: "text.badge.plus") { isEditing = true }
        }
    }

    @ViewBuilder
    private func failureAction(_ failure: AILibraryContentFailure) -> some View {
        switch failure {
        case .needsConsent:
            chip("library_insight_allow_and_generate", systemImage: "sparkles") {
                actions.grantConsentAndGenerate()
            }
        case .notConfigured, .builtInNotOffered:
            if intelligence.shouldExposeRemoteConfiguration {
                LibraryInsightSettingsLink()
                    .buttonStyle(.plain)
                    .font(chipFont)
                    .foregroundStyle(.white)
                    .modifier(LibraryInsightChipBackground(compact: compact))
            }
        case .failed, .noTasteProfile:
            chip("library_insight_retry", systemImage: "arrow.clockwise") { actions.generate() }
                .disabled(store.retryDate(for: subject) != nil)
        }
    }

    /// 说明在上、按钮在下;矮头图里并成一行,说明只留一行。
    @ViewBuilder
    private func noteAndActions<Actions: View>(
        _ text: Text,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        let note = text
            .font(chipFont.weight(.regular))
            .foregroundStyle(.white.opacity(0.78))
        if compact {
            HStack(spacing: 8) {
                note.lineLimit(1)
                Spacer(minLength: 4)
                actions()
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                note.fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) { actions() }
            }
        }
    }

    private func chip(_ title: LocalizedStringKey, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            chipLabel(title, systemImage: systemImage)
        }
        .buttonStyle(.plain)
    }

    private func chipLabel(_ title: LocalizedStringKey, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(chipFont)
            .foregroundStyle(.white)
            .modifier(LibraryInsightChipBackground(compact: compact))
            .contentShape(Capsule())
    }
}

/// 头图上的小胶囊:半透明白底,跟播放键旁边的次要按钮同一种质感。
private struct LibraryInsightChipBackground: ViewModifier {
    var compact = false

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, compact ? 10 : 12)
            .padding(.vertical, compact ? 4 : 7)
            .background(.white.opacity(0.16), in: Capsule())
            .overlay { Capsule().strokeBorder(.white.opacity(0.22), lineWidth: 0.5) }
    }
}

/// 简介全文:风格标签、整段简介、来源和写回结果;编辑、重新生成、删除也在这里。
struct LibraryInsightReaderSheet: View {
    @Environment(\.dismiss) private var dismiss

    let actions: LibraryInsightActions

    @State private var isEditing = false
    @State private var confirmsRegenerate = false

    private var store: LibraryInsightStore { .shared }
    private var subject: LibraryInsightSubject { actions.subject }

    var body: some View {
        let record = store.record(for: subject, in: actions.library)
        Group {
            #if os(macOS)
            VStack(alignment: .leading, spacing: 0) {
                ScrollView {
                    content(record)
                        .padding(24)
                }
                Divider()
                HStack(spacing: 10) {
                    if record?.hasContent == true {
                        Button("library_insight_edit") { isEditing = true }
                        if actions.canAskAI {
                            Button("library_insight_regenerate") { regenerate(record) }
                                .disabled(regenerateDisabled)
                        }
                        Button("library_insight_remove", role: .destructive) {
                            actions.remove()
                            dismiss()
                        }
                    }
                    Spacer()
                    Button("done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                }
                .padding(16)
            }
            .frame(minWidth: 520, idealWidth: 560, minHeight: 360, idealHeight: 440)
            #else
            NavigationStack {
                ScrollView {
                    content(record)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 16)
                }
                .navigationTitle(Text(subject.kind == .album
                    ? LocalizedStringKey("library_insight_album_title")
                    : LocalizedStringKey("library_insight_artist_title")))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("done") { dismiss() }
                    }
                    if record?.hasContent == true {
                        ToolbarItem(placement: .topBarLeading) {
                            Menu {
                                Button {
                                    isEditing = true
                                } label: {
                                    Label("library_insight_edit", systemImage: "pencil")
                                }
                                if actions.canAskAI {
                                    Button {
                                        regenerate(record)
                                    } label: {
                                        Label("library_insight_regenerate", systemImage: "sparkles")
                                    }
                                    .disabled(regenerateDisabled)
                                }
                                Divider()
                                Button(role: .destructive) {
                                    actions.remove()
                                    dismiss()
                                } label: {
                                    Label("library_insight_remove", systemImage: "trash")
                                }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                            }
                            .accessibilityLabel(Text("more"))
                        }
                    }
                }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            #endif
        }
        .sheet(isPresented: $isEditing) {
            LibraryInsightEditorSheet(subject: subject, details: actions.details, record: record) {
                actions.writeBack()
            }
        }
        .confirmationDialog(
            Text("library_insight_regenerate_confirm_title"),
            isPresented: $confirmsRegenerate,
            titleVisibility: .visible
        ) {
            Button("library_insight_regenerate_confirm_action", role: .destructive) { actions.generate() }
            Button("cancel", role: .cancel) {}
        } message: {
            Text("library_insight_regenerate_confirm_message")
        }
    }

    private var regenerateDisabled: Bool {
        store.isGenerating(subject) || store.retryDate(for: subject) != nil
    }

    private func regenerate(_ record: LibraryInsightRecord?) {
        if record?.isWorthKeeping == true {
            confirmsRegenerate = true
        } else {
            actions.generate()
        }
    }

    private var subjectTitle: String {
        subject.kind == .album ? subject.albumTitle : subject.artistName
    }

    private var subjectSubtitle: String? {
        guard subject.kind == .album, !subject.artistName.isEmpty else { return nil }
        return subject.artistName
    }

    private func content(_ record: LibraryInsightRecord?) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: subjectTitle)
                    .font(.title2.weight(.bold))
                    .fixedSize(horizontal: false, vertical: true)
                if let subjectSubtitle {
                    Text(verbatim: subjectSubtitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }

            if let record, !record.tags.isEmpty {
                LibraryInsightTagRow(tags: record.tags)
            }

            if store.isGenerating(subject) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("library_insight_generating")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else if let failure = store.failure(for: subject) {
                Text(verbatim: LibraryInsightStore.message(for: failure))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let record, !record.summary.isEmpty {
                Text(verbatim: record.summary)
                    .font(.body)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            if let record, record.hasContent {
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: LibraryInsightStore.footer(for: record))
                    if let note = store.writebackNote(for: subject) {
                        Text(verbatim: note)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 标签胶囊一行,放不下可以横向滑。
struct LibraryInsightTagRow: View {
    let tags: [String]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(tags, id: \.self) { tag in
                    Text(verbatim: tag)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Color.primary.opacity(0.08), in: Capsule())
                }
            }
        }
    }
}

/// 去智能设置:Mac 开设置窗口,iPhone / iPad 推入设置页。
struct LibraryInsightSettingsLink: View {
    var body: some View {
        #if os(macOS)
        Button("ai_song_discovery_open_settings") {
            SettingsWindowController.shared.show(tab: .intelligence)
        }
        .controlSize(.small)
        #else
        NavigationLink {
            AISettingsView()
                .minimalNavigationDetail()
        } label: {
            Text("ai_song_discovery_open_settings")
                .font(.subheadline.weight(.semibold))
        }
        #endif
    }
}

/// 编辑简介和风格标签。「用 AI 填写」只换掉草稿,点保存才算数。
struct LibraryInsightEditorSheet: View {
    @Environment(MusicIntelligenceService.self) private var intelligence
    @Environment(MusicLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss

    let subject: LibraryInsightSubject
    let details: () -> LibraryInsightSubject
    let onSaved: () -> Void

    @State private var summary: String
    @State private var tagText: String
    @State private var aiDraft: LibraryInsightDraft?
    @State private var aiMessage: String?
    @State private var isFilling = false

    private var store: LibraryInsightStore { .shared }

    init(
        subject: LibraryInsightSubject,
        details: @escaping () -> LibraryInsightSubject,
        record: LibraryInsightRecord?,
        onSaved: @escaping () -> Void
    ) {
        self.subject = subject
        self.details = details
        self.onSaved = onSaved
        _summary = State(initialValue: record?.summary ?? "")
        _tagText = State(initialValue: LibraryInsightEditing.tagText(record?.tags ?? []))
    }

    private var canAskAI: Bool {
        intelligence.isLibraryInsightAvailable || intelligence.libraryInsightNeedsRemoteConsent
    }

    var body: some View {
        #if os(macOS)
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: title)
                .font(.title3.bold())
                .padding([.horizontal, .top], 20)
                .padding(.bottom, 8)
            form
            HStack {
                Spacer()
                Button("cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding(20)
        }
        .frame(minWidth: 520, minHeight: 480)
        #else
        NavigationStack {
            form
                .navigationTitle(Text(verbatim: title))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("save", action: save)
                    }
                }
        }
        #endif
    }

    private var title: String {
        subject.kind == .album
            ? String(localized: "library_insight_editor_title_album")
            : String(localized: "library_insight_editor_title_artist")
    }

    private var subjectLine: String {
        subject.kind == .album
            ? [subject.albumTitle, subject.artistName].filter { !$0.isEmpty }.joined(separator: " · ")
            : subject.artistName
    }

    private var form: some View {
        Form {
            Section {
                Text(verbatim: subjectLine)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            if canAskAI {
                Section {
                    Button(action: fillWithAI) {
                        HStack(spacing: 8) {
                            if isFilling {
                                ProgressView().controlSize(.small)
                                Text("library_insight_ai_filling")
                            } else {
                                Label("library_insight_ai_fill", systemImage: "sparkles")
                            }
                        }
                    }
                    .disabled(isFilling || store.retryDate(for: subject) != nil)
                    if let aiMessage {
                        Text(verbatim: aiMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("library_insight_ai_fill_hint")
                }
            }

            Section {
                TextEditor(text: $summary)
                    .frame(minHeight: 160)
            } header: {
                Text("library_insight_editor_summary")
            }

            Section {
                TextField("library_insight_editor_tags_placeholder", text: $tagText, axis: .vertical)
                let tags = LibraryInsightEditing.tags(fromText: tagText)
                if !tags.isEmpty {
                    LibraryInsightTagRow(tags: tags)
                }
            } header: {
                Text("library_insight_editor_tags")
            }
        }
        #if os(macOS)
        .formStyle(.grouped)
        #endif
    }

    private func fillWithAI() {
        aiMessage = nil
        isFilling = true
        let full = details()
        Task {
            if intelligence.libraryInsightNeedsRemoteConsent {
                try? intelligence.grantRemoteConsent()
            }
            let draft = await store.aiDraft(for: full, intelligence: intelligence)
            isFilling = false
            guard let draft else {
                aiMessage = store.failure(for: subject).map { LibraryInsightStore.message(for: $0) }
                store.clearFailure(for: subject)
                return
            }
            guard draft.answer.known else {
                aiMessage = subject.kind == .album
                    ? String(localized: "library_insight_unknown_album")
                    : String(localized: "library_insight_unknown_artist")
                return
            }
            aiDraft = draft
            summary = draft.answer.summary
            tagText = LibraryInsightEditing.tagText(draft.answer.tags)
        }
    }

    private func save() {
        store.saveEdit(
            details(),
            summary: summary,
            tags: LibraryInsightEditing.tags(fromText: tagText),
            aiDraft: aiDraft,
            library: library
        )
        onSaved()
        dismiss()
    }
}
