import SwiftUI
import PrimuseKit

/// 歌词来源页：这首歌旁边的每一个歌词文件，按格式编号，标出正在用的那个。
/// 点一行就改用那个文件，「编辑」打开那个文件的完整原文。
///
/// 换来源不碰任何文件 —— 只记下选择（`LyricsDocumentPinStore`），再把那份
/// 歌词立刻放进缓存让播放页换过来。改写原文只写回被编辑的那一个文件，
/// 格式、编码都照旧，别的来源原样不动。
struct LyricsSourcesView: View {
    let song: Song
    /// 编辑器里有没存的修改：换来源之后编辑器要整个重新载入，先问一声。
    let editorHasUnsavedChanges: Bool
    /// 换了来源，或改写了正在用的那个文件。外层据此重新载入编辑器、刷新播放页。
    let onActiveDocumentChanged: (Song) -> Void

    @Environment(SourceManager.self) private var sourceManager
    @Environment(SourcesStore.self) private var sourcesStore
    @Environment(MusicLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss

    @State private var listing: LyricsDocumentCatalog.Listing?
    @State private var reloadToken = 0
    /// 按文件路径记的解析摘要与原文，列表加载完在后台挨个读，编辑页打开时直接用。
    @State private var summaries: [String: LyricsDocumentSummary] = [:]
    @State private var contents: [String: LyricsDocumentCatalog.Content] = [:]
    @State private var activatingID: String?
    @State private var pendingSwitchID: String?
    @State private var editingID: String?
    @State private var notice: LyricsSourcesNotice?
    @State private var switchFeedback = 0

    var body: some View {
        container
            .task(id: reloadToken) { await load() }
            .alert(
                notice?.title ?? "",
                isPresented: Binding(
                    get: { notice != nil },
                    set: { if !$0 { notice = nil } }
                )
            ) {
                Button(String(localized: "done"), role: .cancel) {}
            } message: {
                Text(notice?.message ?? "")
            }
            #if os(iOS)
            .sensoryFeedback(.selection, trigger: switchFeedback)
            #endif
    }

    // MARK: - 容器

    #if os(macOS)
    private var container: some View {
        VStack(spacing: 0) {
            if let editingID, let entry = documentEntry(id: editingID) {
                documentEditor(entry)
            } else {
                macHeader
                Rectangle().fill(PMColor.divider).frame(height: 0.5)
                listContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 600, height: 640)
        .background(PMColor.bg)
        .foregroundStyle(PMColor.text)
    }

    private var macHeader: some View {
        HStack(spacing: PMSpace.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "lyrics_sources_title"))
                    .font(.system(size: 14, weight: .semibold))
                Text(songCaption)
                    .font(PMFont.caption)
                    .foregroundStyle(PMColor.textMuted)
                    .lineLimit(1)
            }
            Spacer()
            Button(String(localized: "done")) { dismiss() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, PMSpace.m16)
        .frame(height: 56)
    }
    #else
    private var container: some View {
        NavigationStack {
            listContent
                .navigationTitle(String(localized: "lyrics_sources_title"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(String(localized: "done")) { dismiss() }
                    }
                }
                .navigationDestination(item: $editingID) { id in
                    if let entry = documentEntry(id: id) {
                        documentEditor(entry)
                    }
                }
        }
    }
    #endif

    private var songCaption: String {
        "\(song.title) · \(library.artistDisplayName(for: song) ?? String(localized: "unknown_artist"))"
    }

    // MARK: - 列表

    @ViewBuilder
    private var listContent: some View {
        switch listing {
        case nil:
            VStack(spacing: 12) {
                ProgressView()
                Text(String(localized: "lyrics_sources_loading"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .notFileBased:
            ContentUnavailableView {
                Label(String(localized: "lyrics_sources_not_file_title"), systemImage: "server.rack")
            } description: {
                Text(String(localized: "lyrics_sources_not_file_message"))
            }
        case .unavailable(let message):
            ContentUnavailableView {
                Label(String(localized: "lyrics_sources_unavailable_title"), systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button(String(localized: "retry")) {
                    listing = nil
                    reloadToken += 1
                }
                .buttonStyle(.bordered)
            }
        case .documents(let documents) where documents.entries.isEmpty:
            ContentUnavailableView {
                Label(String(localized: "lyrics_sources_empty_title"), systemImage: "doc.text.magnifyingglass")
            } description: {
                Text(String(localized: "lyrics_sources_empty_message"))
            }
        case .documents(let documents):
            documentList(documents)
        }
    }

    #if os(macOS)
    private func documentList(_ documents: LyricsDocumentCatalog.Documents) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PMSpace.m) {
                notices(documents)
                Text(countText(documents))
                    .font(PMFont.caption.weight(.semibold))
                    .foregroundStyle(PMColor.textMuted)
                    .padding(.horizontal, PMSpace.xs)
                VStack(spacing: 0) {
                    ForEach(Array(documents.entries.enumerated()), id: \.element.id) { index, entry in
                        if index > 0 {
                            Rectangle().fill(PMColor.divider).frame(height: 0.5)
                                .padding(.leading, 76)
                        }
                        row(entry, number: index + 1, documents: documents)
                            .padding(.horizontal, PMSpace.m14)
                            .padding(.vertical, PMSpace.s10)
                    }
                }
                .background(PMColor.card, in: .rect(cornerRadius: PMRadius.l))
                .overlay {
                    RoundedRectangle(cornerRadius: PMRadius.l, style: .continuous)
                        .strokeBorder(PMColor.cardBorder, lineWidth: 0.5)
                }
                Text(footerText(documents))
                    .font(PMFont.caption)
                    .foregroundStyle(PMColor.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, PMSpace.xs)
            }
            .padding(PMSpace.l24)
        }
    }
    #else
    private func documentList(_ documents: LyricsDocumentCatalog.Documents) -> some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 3) {
                    Text(song.title)
                        .font(.headline)
                        .lineLimit(2)
                    Text(library.artistDisplayName(for: song) ?? String(localized: "unknown_artist"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 0, trailing: 4))
            }
            if documents.usesLocalCopy || editorHasUnsavedChanges {
                Section { notices(documents) }
            }
            Section {
                ForEach(Array(documents.entries.enumerated()), id: \.element.id) { index, entry in
                    row(entry, number: index + 1, documents: documents)
                }
            } header: {
                Text(countText(documents))
            } footer: {
                Text(footerText(documents))
            }
        }
        .listStyle(.insetGrouped)
    }
    #endif

    @ViewBuilder
    private func notices(_ documents: LyricsDocumentCatalog.Documents) -> some View {
        if documents.usesLocalCopy {
            noticeRow(
                systemImage: "internaldrive",
                text: String(localized: "lyrics_sources_local_copy")
            )
        }
        if editorHasUnsavedChanges {
            noticeRow(
                systemImage: "exclamationmark.circle",
                text: String(localized: "lyrics_sources_unsaved_banner")
            )
        }
    }

    private func noticeRow(systemImage: String, text: String) -> some View {
        Label {
            Text(text)
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(.orange)
        }
        #if os(macOS)
        .padding(PMSpace.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.10), in: .rect(cornerRadius: PMRadius.l))
        #endif
    }

    private func countText(_ documents: LyricsDocumentCatalog.Documents) -> String {
        String(
            format: String(localized: "lyrics_sources_count %lld"),
            Int64(documents.entries.count)
        )
    }

    private func footerText(_ documents: LyricsDocumentCatalog.Documents) -> String {
        var parts: [String] = []
        parts.append(String(localized: documents.canSwitch
                            ? "lyrics_sources_footer"
                            : "lyrics_sources_footer_cue"))
        parts.append(String(localized: documents.sourceIsWritable
                            ? "lyrics_sources_footer_edit"
                            : "lyrics_sources_footer_read_only"))
        return parts.joined(separator: "\n")
    }

    // MARK: - 行

    private func row(
        _ entry: LyricsDocumentCatalog.Entry,
        number: Int,
        documents: LyricsDocumentCatalog.Documents
    ) -> some View {
        HStack(spacing: 12) {
            Button {
                requestSwitch(entry, in: documents)
            } label: {
                HStack(spacing: 12) {
                    Text(String(format: "%02d", number))
                        .font(.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(entry.isActive ? Color.accentColor : Color.secondary)
                        .frame(minWidth: 22, alignment: .leading)
                    selectionMark(entry)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.name)
                            .font(.body.weight(entry.isActive ? .semibold : .regular))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .multilineTextAlignment(.leading)
                        HStack(spacing: 6) {
                            LyricsDocumentFormatBadge(format: entry.format)
                            if entry.isActive {
                                Text(String(localized: "lyrics_sources_in_use"))
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(Color.accentColor)
                            }
                            let detail = detailText(entry)
                            if !detail.isEmpty {
                                Text(detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(entry.isActive ? .isSelected : [])
            .confirmationDialog(
                String(format: String(localized: "lyrics_sources_switch_confirm_title %@"), entry.name),
                isPresented: Binding(
                    get: { pendingSwitchID == entry.id },
                    set: { if !$0 { pendingSwitchID = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button(String(localized: "lyrics_sources_switch_action")) {
                    Task { await activate(entry) }
                }
                Button(String(localized: "cancel"), role: .cancel) {}
            } message: {
                Text(String(localized: "lyrics_sources_switch_confirm_message"))
            }

            Button(String(localized: entry.isEditable ? "lyrics_sources_edit" : "lyrics_sources_view")) {
                editingID = entry.id
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(activatingID != nil)
        }
        .padding(.vertical, 2)
    }

    private func selectionMark(_ entry: LyricsDocumentCatalog.Entry) -> some View {
        ZStack {
            if activatingID == entry.id {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: entry.isActive ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 21))
                    .foregroundStyle(entry.isActive ? Color.accentColor : Color.secondary.opacity(0.45))
                    .symbolEffect(.bounce, value: entry.isActive)
            }
        }
        .frame(width: 24, height: 24)
    }

    private func detailText(_ entry: LyricsDocumentCatalog.Entry) -> String {
        var parts: [String] = []
        if let summary = summaries[entry.id] {
            let key: String.LocalizationValue = summary.isWordLevel
                ? "lyrics_sources_summary_word %lld"
                : (summary.isSynchronized
                    ? "lyrics_sources_summary_line %lld"
                    : "lyrics_sources_summary_plain %lld")
            parts.append(String(format: String(localized: key), Int64(summary.lineCount)))
        }
        if entry.document.size > 0 {
            parts.append(ByteCountFormatter.string(fromByteCount: entry.document.size, countStyle: .file))
        }
        if entry.translation != nil {
            parts.append(String(localized: "lyrics_sources_with_translation"))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - 编辑页

    private func documentEditor(_ entry: LyricsDocumentCatalog.Entry) -> some View {
        LyricsDocumentEditorView(
            song: song,
            entry: entry,
            preloaded: contents[entry.id],
            onSaved: { saved, outcome in
                contents[entry.id] = saved
                summaries[entry.id] = LyricsDocumentSummary(lines: LyricsParser.parse(saved.text))
                if entry.isActive, let updated = outcome.updatedSong {
                    onActiveDocumentChanged(updated)
                }
                // 文件大小变了，重新列一次，下次打开按新的长度读。
                reloadToken += 1
            },
            onClose: { editingID = nil }
        )
    }

    private func documentEntry(id: String) -> LyricsDocumentCatalog.Entry? {
        guard case .documents(let documents) = listing else { return nil }
        return documents.entries.first { $0.id == id }
    }

    // MARK: - 动作

    private func load() async {
        let result = await LyricsDocumentCatalog.load(
            for: song,
            sourceManager: sourceManager,
            sourcesStore: sourcesStore
        )
        guard !Task.isCancelled else { return }
        listing = result
        guard case .documents(let documents) = result else { return }
        // 摘要要把每个文件读一遍。挨个读、读完一个显示一个，列表本身不等它们。
        for entry in documents.entries where summaries[entry.id] == nil || contents[entry.id] == nil {
            guard !Task.isCancelled else { return }
            guard let content = try? await LyricsDocumentCatalog.read(
                entry.document,
                for: song,
                sourceManager: sourceManager
            ) else { continue }
            guard !Task.isCancelled else { return }
            contents[entry.id] = content
            summaries[entry.id] = LyricsDocumentSummary(lines: LyricsParser.parse(content.text))
        }
    }

    private func requestSwitch(
        _ entry: LyricsDocumentCatalog.Entry,
        in documents: LyricsDocumentCatalog.Documents
    ) {
        guard activatingID == nil else { return }
        guard documents.canSwitch else {
            notice = LyricsSourcesNotice(
                title: String(localized: "lyrics_sources_title"),
                message: String(localized: "lyrics_sources_footer_cue")
            )
            return
        }
        // 已经在用、也没有被本地版本盖住：什么都不用做。
        guard !entry.isActive || documents.usesLocalCopy else { return }
        if editorHasUnsavedChanges {
            pendingSwitchID = entry.id
            return
        }
        Task { await activate(entry) }
    }

    private func activate(_ entry: LyricsDocumentCatalog.Entry) async {
        activatingID = entry.id
        defer { activatingID = nil }
        do {
            try await LyricsDocumentCatalog.activate(entry, for: song, sourceManager: sourceManager)
            if case .documents(let documents) = listing {
                withAnimation(.snappy) {
                    listing = .documents(documents.activating(entry.id))
                }
            }
            switchFeedback += 1
            onActiveDocumentChanged(library.song(id: song.id) ?? song)
        } catch {
            notice = LyricsSourcesNotice(
                title: String(localized: "lyrics_sources_switch_failed_title"),
                message: error.localizedDescription
            )
        }
    }
}

struct LyricsSourcesNotice: Equatable {
    let title: String
    let message: String
    /// 文件在别处被改过：给一个重新载入的按钮。
    var offersReload = false
    /// 已经存好了，只是附带的一步没成：看完就离开编辑页。
    var closesEditor = false
}

/// 文件格式的小胶囊。按内容的种类配色：LRC 一类、TTML、毫秒逐字（LYS/YRC/QRC）、字幕。
struct LyricsDocumentFormatBadge: View {
    let format: LyricsDocumentFormat?

    var body: some View {
        Text(format?.label ?? "—")
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .tracking(0.4)
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.14), in: Capsule())
            .accessibilityLabel(format?.label ?? "")
    }

    private var tint: Color {
        switch format?.family {
        case .lrc: return .blue
        case .ttml: return .purple
        case .wordTimed: return .orange
        case .subtitle: return .teal
        case nil: return .gray
        }
    }
}

// MARK: - 原文编辑页

/// 一个歌词文件的完整原文。保存时按原来的格式和编码写回这一个文件；
/// 写回前确认文件还是打开时的样子，写完逐字节回读。
struct LyricsDocumentEditorView: View {
    let song: Song
    let entry: LyricsDocumentCatalog.Entry
    let preloaded: LyricsDocumentCatalog.Content?
    let onSaved: (LyricsDocumentCatalog.Content, LyricsWriteback.DocumentSaveOutcome) -> Void
    let onClose: () -> Void

    @Environment(SourceManager.self) private var sourceManager
    @Environment(MusicLibrary.self) private var library

    @State private var content: LyricsDocumentCatalog.Content?
    @State private var text = ""
    @State private var loadError: String?
    @State private var validation: LyricsRawDocumentPolicy.Validation?
    @State private var isSaving = false
    @State private var notice: LyricsSourcesNotice?
    @State private var showDiscardConfirm = false
    @State private var loadToken = 0

    private var hasChanges: Bool {
        guard let content else { return false }
        return content.text != text
    }

    var body: some View {
        editorContainer
            .task(id: loadToken) { await load() }
            .task(id: text) { await validateAfterPause() }
            .overlay {
                if isSaving {
                    ZStack {
                        Color.black.opacity(0.18)
                        ProgressView()
                            .padding(18)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .ignoresSafeArea()
                }
            }
            .alert(
                notice?.title ?? "",
                isPresented: Binding(
                    get: { notice != nil },
                    set: { if !$0 { notice = nil } }
                ),
                presenting: notice
            ) { presented in
                if presented.offersReload {
                    Button(String(localized: "lyrics_sources_reload")) { reloadFromSource() }
                    Button(String(localized: "cancel"), role: .cancel) {}
                } else {
                    Button(String(localized: "done"), role: .cancel) {
                        if presented.closesEditor { onClose() }
                    }
                }
            } message: { presented in
                Text(presented.message)
            }
    }

    // MARK: 容器

    #if os(macOS)
    private var editorContainer: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button {
                    if hasChanges { showDiscardConfirm = true } else { onClose() }
                } label: {
                    Label(String(localized: hasChanges ? "cancel" : "lyrics_sources_title"),
                          systemImage: hasChanges ? "xmark" : "chevron.left")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .keyboardShortcut(.cancelAction)
                .confirmationDialog(
                    String(localized: "lyrics_sources_discard_title"),
                    isPresented: $showDiscardConfirm,
                    titleVisibility: .visible
                ) {
                    discardActions
                }

                VStack(spacing: 1) {
                    Text(String(localized: entry.isEditable ? "lyrics_sources_editor_title" : "lyrics_sources_viewer_title"))
                        .font(.system(size: 13.5, weight: .semibold))
                    Text(entry.name)
                        .font(PMFont.caption)
                        .foregroundStyle(PMColor.textMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity)

                if entry.isEditable {
                    Button(String(localized: "save")) { Task { await save() } }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .keyboardShortcut("s", modifiers: .command)
                        .disabled(!hasChanges || isSaving)
                } else {
                    Color.clear.frame(width: 60, height: 1)
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 56)
            Rectangle().fill(PMColor.divider).frame(height: 0.5)
            editorBody
        }
    }
    #else
    private var editorContainer: some View {
        editorBody
            .navigationTitle(String(localized: entry.isEditable ? "lyrics_sources_editor_title" : "lyrics_sources_viewer_title"))
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden(hasChanges || isSaving)
            .interactiveDismissDisabled(hasChanges || isSaving)
            .toolbar {
                if hasChanges {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(String(localized: "cancel")) { showDiscardConfirm = true }
                            .disabled(isSaving)
                            .confirmationDialog(
                                String(localized: "lyrics_sources_discard_title"),
                                isPresented: $showDiscardConfirm,
                                titleVisibility: .visible
                            ) {
                                discardActions
                            }
                    }
                }
                if entry.isEditable {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(String(localized: "save")) { Task { await save() } }
                            .fontWeight(.semibold)
                            .disabled(!hasChanges || isSaving)
                    }
                }
            }
    }
    #endif

    @ViewBuilder
    private var discardActions: some View {
        Button(String(localized: "lyrics_sources_discard"), role: .destructive) {
            if let content { text = content.text }
            onClose()
        }
        Button(String(localized: "cancel"), role: .cancel) {}
    }

    @ViewBuilder
    private var editorBody: some View {
        if let loadError {
            ContentUnavailableView {
                Label(String(localized: "lyrics_sources_unavailable_title"), systemImage: "exclamationmark.triangle")
            } description: {
                Text(loadError)
            } actions: {
                Button(String(localized: "retry")) { reloadFromSource() }
                    .buttonStyle(.bordered)
            }
        } else if content == nil {
            VStack(spacing: 12) {
                ProgressView()
                Text(String(localized: "lyrics_sources_editor_loading"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                statusBar
                Divider()
                if entry.isEditable {
                    TextEditor(text: $text)
                        .font(.system(size: 13, design: .monospaced))
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .scrollContentBackground(.hidden)
                        .padding(.horizontal, 8)
                } else {
                    ScrollView {
                        Text(text)
                            .font(.system(size: 13, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                    }
                }
            }
        }
    }

    private var statusBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                LyricsDocumentFormatBadge(format: entry.format)
                Text(entry.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if entry.isActive {
                    Text(String(localized: "lyrics_sources_in_use"))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
                Spacer(minLength: 0)
            }
            let status = statusLine
            if !status.text.isEmpty {
                Label {
                    Text(status.text)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: status.systemImage)
                }
                .font(.caption)
                .foregroundStyle(status.tint)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var statusLine: (text: String, systemImage: String, tint: Color) {
        guard entry.isEditable else {
            return (String(localized: "lyrics_sources_editor_read_only"), "eye", .secondary)
        }
        guard let validation else { return ("", "circle", .secondary) }
        if let message = LyricsDocumentCatalog.message(for: validation.outcome, fileName: entry.name) {
            return (message, "xmark.octagon", .red)
        }
        if !validation.unreadableLineNumbers.isEmpty {
            let numbers = validation.unreadableLineNumbers.prefix(8).map(String.init)
                .joined(separator: ", ")
                + (validation.unreadableLineNumbers.count > 8 ? "…" : "")
            return (
                String(format: String(localized: "lyrics_sources_validation_lines %@"), numbers),
                "exclamationmark.triangle",
                .orange
            )
        }
        var parts: [String] = []
        if case .valid(let summary) = validation.outcome {
            let key: String.LocalizationValue = summary.isWordLevel
                ? "lyrics_sources_summary_word %lld"
                : (summary.isSynchronized
                    ? "lyrics_sources_summary_line %lld"
                    : "lyrics_sources_summary_plain %lld")
            parts.append(String(format: String(localized: key), Int64(summary.lineCount)))
        }
        if hasChanges {
            parts.append(String(format: String(localized: "lyrics_sources_editor_writes_back %@"), entry.name))
        }
        return (parts.joined(separator: " · "), "checkmark.circle", .secondary)
    }

    // MARK: 动作

    private func load() async {
        if loadToken == 0, let preloaded {
            content = preloaded
            text = preloaded.text
            return
        }
        loadError = nil
        do {
            let fresh = try await LyricsDocumentCatalog.readFresh(
                named: entry.name,
                for: song,
                sourceManager: sourceManager
            )
            guard !Task.isCancelled else { return }
            content = fresh
            text = fresh.text
        } catch {
            guard !Task.isCancelled else { return }
            loadError = error.localizedDescription
        }
    }

    private func reloadFromSource() {
        content = nil
        validation = nil
        loadToken += 1
    }

    /// 打字时不必每个字都解析一遍整份 TTML：停一下再查，放到主线程外。
    private func validateAfterPause() async {
        guard content != nil else { return }
        try? await Task.sleep(for: .milliseconds(350))
        guard !Task.isCancelled else { return }
        let snapshot = text
        let fileName = entry.name
        let result = await Task.detached(priority: .userInitiated) {
            LyricsRawDocumentPolicy.validate(snapshot, fileName: fileName)
        }.value
        guard !Task.isCancelled, snapshot == text else { return }
        validation = result
    }

    private func save() async {
        guard let content, hasChanges, !isSaving else { return }
        let check = LyricsRawDocumentPolicy.validate(text, fileName: entry.name)
        if let message = LyricsDocumentCatalog.message(for: check.outcome, fileName: entry.name) {
            notice = LyricsSourcesNotice(
                title: String(localized: "lyrics_sources_cannot_save_title"),
                message: message
            )
            return
        }
        isSaving = true
        let saved = text
        let outcome = await LyricsWriteback.saveDocument(
            entry,
            text: saved,
            original: content,
            for: song,
            sourceManager: sourceManager,
            library: library
        )
        isSaving = false
        guard outcome.succeeded else {
            notice = LyricsSourcesNotice(
                title: String(localized: "tag_editor_lyrics_error_title"),
                message: outcome.errorMessage ?? "",
                offersReload: outcome.changedElsewhere
            )
            return
        }
        let baseline = LyricsDocumentCatalog.Content(
            text: saved,
            data: content.encoding.data(for: saved),
            encoding: content.encoding
        )
        self.content = baseline
        onSaved(baseline, outcome)
        if let embeddedCopyError = outcome.embeddedCopyError {
            notice = LyricsSourcesNotice(
                title: String(localized: "done"),
                message: String(format: String(localized: "lyrics_embed_copy_failed_format"), embeddedCopyError),
                closesEditor: true
            )
        } else {
            onClose()
        }
    }
}
