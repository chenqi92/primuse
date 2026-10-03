import SwiftUI
import PrimuseKit

/// 专辑页 / 艺人页里的「关于这张专辑」「关于这位艺人」:简介和风格标签。
/// 可以自己写、随时改,也可以让 AI 填写;内容存在曲库里,随曲库同步。
struct LibraryInsightCard: View {
    @Environment(MusicIntelligenceService.self) private var intelligence
    @Environment(MusicLibrary.self) private var library
    @Environment(SourceManager.self) private var sourceManager
    @Environment(SourcesStore.self) private var sourcesStore

    /// 只用名字认出是哪张专辑/哪位艺人;曲目、风格等在要问 AI 时才由 `details` 收集。
    let subject: LibraryInsightSubject
    let details: () -> LibraryInsightSubject
    /// 这张专辑 / 这位艺人在曲库里的歌:写回音乐源、从音乐源读简介时用。
    let songs: () -> [Song]
    #if os(iOS)
    var tint: LibraryDetailTintStyle?
    #endif

    @State private var isExpanded = false
    @State private var isEditing = false
    @State private var confirmsRegenerate = false

    private var store: LibraryInsightStore { .shared }

    private var canAskAI: Bool {
        intelligence.isLibraryInsightAvailable
            || intelligence.libraryInsightNeedsRemoteConsent
            || intelligence.shouldExposeRemoteConfiguration
    }

    #if DEBUG
    /// 截图钩子:`PRIMUSE_DEBUG_INSIGHT_EDIT=1` 让首个出现的简介卡片打开编辑页,只开一次
    /// (配合 `PRIMUSE_OPEN_PAGE=artist:<名字>` 看染色详情页里弹出的编辑页)。
    @MainActor private static var didOpenDebugEditor = false

    private func openDebugEditorIfRequested() async {
        guard !Self.didOpenDebugEditor,
              ProcessInfo.processInfo.environment["PRIMUSE_DEBUG_INSIGHT_EDIT"] == "1" else { return }
        Self.didOpenDebugEditor = true
        try? await Task.sleep(for: .seconds(3))
        guard !Task.isCancelled else { return }
        plog("🧪 Debug: open insight editor")
        isEditing = true
    }
    #endif

    var body: some View {
        let record = store.record(for: subject, in: library)
        if LibraryInsightStore.isIntroducible(subject) {
            VStack(alignment: .leading, spacing: 10) {
                header(record)
                content(record)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            #if os(iOS)
            .libraryDetailSection(tint: tint)
            #else
            .pmGlass(cornerRadius: PMRadius.m10)
            #endif
            .pmAnimation(.control, value: store.isGenerating(subject))
            // 编辑页挂在透明宿主上:卡片在染色详情页里是深色外观,弹出页要在宿主外层
            // 换回 App 本来的外观,否则浅色模式下会白底白字。
            .background {
                Color.clear
                    .sheet(isPresented: $isEditing) {
                        LibraryInsightEditorSheet(subject: subject, details: details, record: record, onSaved: writeBack)
                    }
                    .libraryDetailPresentationReset()
            }
            #if DEBUG
            .task { await openDebugEditorIfRequested() }
            #endif
            .task(id: store.recordID(for: subject)) {
                guard store.record(for: subject, in: library) == nil else { return }
                await LibraryInsightWriteback.importIfAvailable(
                    subject: subject,
                    songs: songs(),
                    library: library,
                    sourceManager: sourceManager,
                    sourcesStore: sourcesStore
                )
            }
            .confirmationDialog(
                Text("library_insight_regenerate_confirm_title"),
                isPresented: $confirmsRegenerate,
                titleVisibility: .visible
            ) {
                Button("library_insight_regenerate_confirm_action", role: .destructive, action: generate)
                Button("cancel", role: .cancel) {}
            } message: {
                Text("library_insight_regenerate_confirm_message")
            }
        }
    }

    private func header(_ record: LibraryInsightRecord?) -> some View {
        HStack(spacing: 8) {
            Label(
                subject.kind == .album
                    ? LocalizedStringKey("library_insight_album_title")
                    : LocalizedStringKey("library_insight_artist_title"),
                systemImage: "text.quote"
            )
            .font(.headline)
            Spacer(minLength: 8)
            if record != nil, !store.isGenerating(subject) {
                Menu {
                    Button {
                        isEditing = true
                    } label: {
                        Label("library_insight_edit", systemImage: "pencil")
                    }
                    if canAskAI {
                        Button {
                            if record?.isWorthKeeping == true {
                                confirmsRegenerate = true
                            } else {
                                generate()
                            }
                        } label: {
                            Label("library_insight_regenerate", systemImage: "sparkles")
                        }
                        .disabled(store.retryDate(for: subject) != nil)
                    }
                    Divider()
                    Button(role: .destructive) {
                        store.remove(subject, library: library)
                        writeBack()
                    } label: {
                        Label("library_insight_remove", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                #if os(macOS)
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                #endif
                .accessibilityLabel(Text("more"))
            }
        }
    }

    @ViewBuilder
    private func content(_ record: LibraryInsightRecord?) -> some View {
        if store.isGenerating(subject) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("library_insight_generating")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        } else if let failure = store.failure(for: subject) {
            failureView(failure)
        } else if let record, record.hasContent {
            recordView(record)
        } else if let record, record.aiKnown == false {
            VStack(alignment: .leading, spacing: 10) {
                Text(subject.kind == .album
                    ? LocalizedStringKey("library_insight_unknown_album")
                    : LocalizedStringKey("library_insight_unknown_artist"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                actionButtons(showsGenerate: false)
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text(subject.kind == .album
                    ? LocalizedStringKey("library_insight_prompt_album")
                    : LocalizedStringKey("library_insight_prompt_artist"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                actionButtons(showsGenerate: canAskAI)
            }
        }
    }

    private func actionButtons(showsGenerate: Bool) -> some View {
        HStack(spacing: 10) {
            if showsGenerate {
                Button(action: generate) {
                    Label("library_insight_generate", systemImage: "sparkles")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            Button {
                isEditing = true
            } label: {
                Label("library_insight_write_own", systemImage: "pencil")
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private func recordView(_ record: LibraryInsightRecord) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if !record.summary.isEmpty {
                Text(verbatim: record.summary)
                    .font(.subheadline)
                    .lineSpacing(3)
                    .lineLimit(isExpanded ? nil : 4)
                    .fixedSize(horizontal: false, vertical: true)
                    #if os(macOS)
                    .textSelection(.enabled)
                    #endif
                if record.summary.count > 90 || record.summary.contains("\n") {
                    Button(isExpanded ? LocalizedStringKey("library_insight_less") : LocalizedStringKey("more")) {
                        isExpanded.toggle()
                    }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                }
            }
            if !record.tags.isEmpty {
                LibraryInsightTagRow(tags: record.tags)
            }
            Text(verbatim: LibraryInsightStore.footer(for: record))
                .font(.caption2)
                .foregroundStyle(.tertiary)
            if let note = store.writebackNote(for: subject) {
                Text(verbatim: note)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func failureView(_ failure: AILibraryContentFailure) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: LibraryInsightStore.message(for: failure))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                switch failure {
                case .needsConsent:
                    Button("library_insight_allow_and_generate") {
                        do {
                            try intelligence.grantRemoteConsent()
                            generate()
                        } catch {
                            store.clearFailure(for: subject)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                case .notConfigured, .builtInNotOffered:
                    if intelligence.shouldExposeRemoteConfiguration {
                        LibraryInsightSettingsLink()
                    }
                case .failed, .noTasteProfile:
                    Button(action: generate) {
                        Label("library_insight_retry", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(store.retryDate(for: subject) != nil)
                }
                Button("library_insight_write_own") {
                    store.clearFailure(for: subject)
                    isEditing = true
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private func generate() {
        isExpanded = false
        let full = details()
        Task {
            await store.generate(full, library: library, intelligence: intelligence)
            if store.failure(for: subject) == nil { writeBack() }
        }
    }

    /// 存下来的简介按各音乐源能写的方式写出去,结果显示在卡片底部。
    private func writeBack() {
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
