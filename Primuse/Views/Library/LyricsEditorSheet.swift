import SwiftUI
import PrimuseKit

struct LyricsVersionDraft {
    let entry: LyricsDocumentCatalog.Entry
    let original: LyricsDocumentCatalog.Content
    let baseline: LyricsEditorDocument
    var document: LyricsEditorDocument
    var timingEligibleIndices: [Int] = []
    var needsTimingRepair = false
    var unstampedCount = 0
    var allowsPartialTiming = false

    @MainActor
    func save(for song: Song, sourceManager: SourceManager, library: MusicLibrary,
              mode: LyricsDocumentCatalog.VersionSaveMode = .replace) async throws {
        let prepared = document.preparedForTimingCommit(eligibleIndices: timingEligibleIndices)
        try await LyricsDocumentCatalog.saveEditedLines(
            prepared.lyricLines(), text: prepared.serialized(), entry: entry,
            original: original, for: song, sourceManager: sourceManager, library: library, mode: mode
        )
    }
}

/// 歌词编辑的独立入口。跟「编辑标签」平级 —— 调歌词是高频且自成一件事的操作，
/// 不该埋在标签编辑器里再点一层。
///
/// 内容直接复用 `LyricsEditorView`(文本 / 打轴双模式)，这一层只负责把歌词
/// 读进来、把编辑结果写回去，以及处理"清空歌词需要二次确认"这个破坏性分支。
struct LyricsEditorSheet: View {
    let song: Song
    var autoStartsAudioTranscription = false
    var onSave: ((Song) -> Void)?
    var onLoad: ((Song, [LyricLine]) -> Void)?

    @Environment(MusicLibrary.self) private var library
    @Environment(SourceManager.self) private var sourceManager
    @Environment(SourcesStore.self) private var sourcesStore
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var originalText = ""
    @State private var initialLines: [LyricLine]?
    @State private var pendingStructuredLines: [LyricLine]?
    @State private var sourceSnapshot: LyricsWriteback.EditableSourceSnapshot = .unknown
    @State private var cacheSnapshot: LyricsDocumentFingerprint?
    @State private var target: LyricsWriteback.Target = .checking
    @State private var hasSourceConflict = false
    /// 写回目标的探测。它跟读歌词是两件独立的网络活，一起发出去，
    /// 只有保存时才需要它的结果。
    @State private var writebackProbe: Task<LyricsWriteback.Target, Never>?
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var completionMessage: String?
    /// 保存完只存在 Primuse 时,提示里给的解决办法(授权所在文件夹、改成嵌入)。
    @State private var completionRemedies: [SaveLocationPolicy.Remedy] = []
    @State private var showFolderAccessPicker = false
    @State private var pendingEmbedRemedy: SaveLocationPolicy.Remedy?
    /// 歌词已经存进 Primuse、补救那一步出了错:报错关掉后照样关掉编辑器,不卡在半截。
    @State private var dismissesAfterError = false
    /// 待确认删除的内容。非 nil 表示用户清空了歌词、正在等二次确认。
    @State private var pendingRemoval = false

    var body: some View {
        Group {
            if isLoading {
                loadingView
            } else {
                LyricsEditorView(
                    song: song,
                    text: $text,
                    initialLines: initialLines,
                    autoStartsAudioTranscription: autoStartsAudioTranscription,
                    allowsStructuredOnlyTranslationEditing: LyricsWriteback
                        .allowsStructuredOnlyTranslationEditing(for: initialLines, mode: target.mode),
                    onVersionsChanged: { _ in
                        let updated = library.song(id: song.id) ?? song
                        onSave?(updated)
                        await refreshAfterVersionChange()
                    },
                    onCommit: { committed, lines in
                        handleCommit(committed, structuredLines: lines)
                    }
                )
                .overlay {
                    if isSaving { savingOverlay }
                }
            }
        }
        .task(id: song.id) { await load() }
        .onDisappear { cancelWritebackProbe() }
        .alert(
            String(localized: "tag_editor_lyrics_error_title"),
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button(String(localized: "done"), role: .cancel) {
                guard dismissesAfterError else { return }
                dismissesAfterError = false
                dismiss()
            }
        } message: {
            Text(errorMessage ?? "")
        }
        .alert(
            String(localized: "done"),
            isPresented: Binding(
                get: { completionMessage != nil },
                set: { if !$0 { completionMessage = nil } }
            )
        ) {
            // 只存在 Primuse 的:给解决办法,办完回到这里把歌词写进文件。
            ForEach(completionRemedies, id: \.self) { remedy in
                Button(remedy.title) { startRemedy(remedy) }
            }
            Button(String(localized: "done")) { dismiss() }
        } message: {
            Text(completionMessage ?? "")
        }
        .modifier(SaveLocationRemedyPrompts(
            showsFolderPicker: $showFolderAccessPicker,
            pendingEmbedRemedy: $pendingEmbedRemedy,
            onFolderPicked: { result in handleFolderAccessPick(result) },
            onEmbedConfirmed: { remedy in
                remedy.applyEmbedding(for: song.id)
                Task { await saveAgainAfterRemedy(grantedFolder: false) }
            },
            onCancelled: { dismiss() }
        ))
        // 由编辑器的完成回调发起（可能隔着打轴提醒或修复面板），没有可挂的按钮，用居中的 alert。
        .alert(
            String(localized: "tag_editor_lyrics_delete_confirm_title"),
            isPresented: $pendingRemoval
        ) {
            Button(String(localized: "tag_editor_lyrics_delete"), role: .destructive) {
                Task { await save(allowRemoval: true) }
            }
            Button(String(localized: "cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "tag_editor_lyrics_delete_confirm_message"))
        }
    }

    /// 加载态必须自带退出口。iOS 上这个编辑器是 fullScreenCover，没有下滑关闭，
    /// 歌词还在从音乐源读的时候，一个没有按钮的转圈就是把用户关在里面。
    private var loadingView: some View {
        #if os(macOS)
        VStack(spacing: 0) {
            loadingIndicator
            Rectangle().fill(PMColor.divider).frame(height: 0.5)
            HStack {
                Spacer()
                Button(String(localized: "cancel")) { cancelLoading() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(width: 820, height: 680)
        .background(PMColor.bg)
        #else
        VStack(spacing: 0) {
            // 位置和编辑器自己的「取消」对齐，读完切过去时按钮不跳。
            HStack {
                Button(String(localized: "cancel")) { cancelLoading() }
                    .font(.subheadline)
                    .contentShape(Rectangle())
                Spacer(minLength: 0)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            Divider()
            loadingIndicator
        }
        #endif
    }

    private var loadingIndicator: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("lyrics_loading")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 写回可能要走网盘/NAS，慢的时候盖一层，避免用户以为卡住又点一次。
    private var savingOverlay: some View {
        ZStack {
            Color.black.opacity(0.18)
            ProgressView()
                .padding(18)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .ignoresSafeArea()
    }

    private func load() async {
        isLoading = true
        target = .checking
        // 读权威歌词和探测写回目标互不依赖，之前却排成一条线走。两段各自要
        // 列一次歌曲所在目录，写回探测还要另开一条连接重新登录 —— NAS / 网盘上
        // 这两段加起来就是用户干等的那几十秒。一起发出去，只等慢的那个。
        let probe = startWritebackProbe()
        let loaded = await LyricsWriteback.loadEditablePayload(
            for: song,
            sourceManager: sourceManager
        )
        guard !Task.isCancelled else { return }
        text = loaded.text
        originalText = loaded.text
        initialLines = loaded.structuredLines
        pendingStructuredLines = nil
        sourceSnapshot = loaded.sourceSnapshot
        cacheSnapshot = loaded.cacheSnapshot
        hasSourceConflict = loaded.hasSourceConflict
        onLoad?(song, loaded.playbackLines)
        // 歌词到手就能开始编辑。写回目标只有按「完成」时才用得上，让它在后台
        // 探完，不必把整个编辑器挡在后面。
        isLoading = false
        let resolved = await probe.value
        guard !Task.isCancelled else { return }
        target = resolved.protectingSourceConflict(loaded.hasSourceConflict)
    }

    private func refreshAfterVersionChange() async {
        let updated = library.song(id: song.id) ?? song
        let loaded = await LyricsWriteback.loadEditablePayload(for: updated, sourceManager: sourceManager)
        guard !Task.isCancelled else { return }
        originalText = loaded.text
        text = loaded.text
        initialLines = loaded.structuredLines
        pendingStructuredLines = nil
        sourceSnapshot = loaded.sourceSnapshot
        cacheSnapshot = loaded.cacheSnapshot
        hasSourceConflict = loaded.hasSourceConflict
        let probe = startWritebackProbe()
        target = await probe.value.protectingSourceConflict(loaded.hasSourceConflict)
    }

    private func startWritebackProbe() -> Task<LyricsWriteback.Target, Never> {
        writebackProbe?.cancel()
        let probe = Task { @MainActor in
            await LyricsWriteback.resolveTarget(
                for: song,
                sourceManager: sourceManager,
                sourcesStore: sourcesStore
            )
        }
        writebackProbe = probe
        return probe
    }

    private func cancelWritebackProbe() {
        writebackProbe?.cancel()
        writebackProbe = nil
    }

    private func cancelLoading() {
        cancelWritebackProbe()
        dismiss()
    }

    /// 保存时写回目标可能还没探完。拿 `.checking` 去存会被当成失败，
    /// 把「正在检查音乐源写入权限」当错误弹出来 —— 这里先等探测出结果，
    /// 等待期间保存遮罩已经盖住界面。
    private func resolvedWritebackTarget() async -> LyricsWriteback.Target {
        if case .checking = target.mode {
            let probe = writebackProbe ?? startWritebackProbe()
            target = await probe.value.protectingSourceConflict(hasSourceConflict)
        }
        // 探测是跟读歌词一起发出去的，源正忙时它可能先撞上自己的超时。保存是
        // 用户主动发起的，这会儿连接已经空出来了，值得为它再探一次，而不是拿
        // 一次「暂时连不上」把改好的歌词挡回去。
        if case .temporarilyUnavailable = target.mode {
            target = await startWritebackProbe().value
                .protectingSourceConflict(hasSourceConflict)
        }
        return target
    }

    /// 编辑器点了「完成」。没改动直接关；清空了先确认；否则落盘。
    private func handleCommit(_ committed: String, structuredLines: [LyricLine]) {
        text = committed
        pendingStructuredLines = structuredLines

        let structureChanged = initialLines.map {
            LyricsDocumentFingerprint(lines: $0)
                != LyricsDocumentFingerprint(lines: structuredLines)
        } ?? false
        guard structureChanged
                || LyricsWriteback.normalized(committed)
                    != LyricsWriteback.normalized(originalText) else {
            dismiss()
            return
        }

        // 从"有歌词"改成"没歌词"是删除，先确认再落盘。
        if LyricsWriteback.normalized(committed).isEmpty,
           !LyricsWriteback.normalized(originalText).isEmpty {
            pendingRemoval = true
            return
        }

        Task { await save(allowRemoval: false) }
    }

    private func save(allowRemoval: Bool) async {
        guard !isSaving else { return }
        isSaving = true
        let writebackTarget = await resolvedWritebackTarget()
        let outcome = await LyricsWriteback.save(
            text: text,
            for: song,
            mode: writebackTarget.mode,
            allowRemoval: allowRemoval,
            structuredLines: pendingStructuredLines,
            sourceSnapshot: sourceSnapshot,
            cacheSnapshot: cacheSnapshot,
            sourceManager: sourceManager,
            library: library
        )
        isSaving = false

        guard outcome.succeeded else {
            // 留在编辑器里，把错误摆出来 —— 关掉会让用户以为已经存上了。
            errorMessage = outcome.errorMessage
            return
        }

        originalText = text
        cacheSnapshot = outcome.cacheSnapshot
        onSave?(outcome.updatedSong)
        if let notice = outcome.notice {
            // 存成功了，但有一句要让用户知道的话(清空后文件里的歌词还在、只在 Primuse 里隐藏了等)。
            completionMessage = notice
            completionRemedies = []
            return
        }
        if outcome.persistence == .localOnly {
            // 落在哪里、为什么、之后会不会自动写进文件;能一键解决的给按钮。
            completionMessage = LyricsWriteback.keptLocallyMessage(requested: writebackTarget)
            completionRemedies = writebackTarget.plan.remedies
            return
        }
        if let embeddedCopyError = outcome.embeddedCopyError {
            // 歌词文件已经存好了，只是音频文件里的那份没写成；说清楚再让用户关。
            completionMessage = String(
                format: String(localized: "lyrics_embed_copy_failed_format"),
                embeddedCopyError
            )
            completionRemedies = []
            return
        }
        if writebackTarget.plan.reason != .none {
            // 和设置不一样的落点(单独添加的文件只嵌入了、格式不能嵌入只写了歌词文件):说一声。
            completionMessage = writebackTarget.fullNotice
            completionRemedies = writebackTarget.plan.remedies
            return
        }
        dismiss()
    }

    // MARK: - 保存位置:解决办法

    private func startRemedy(_ remedy: SaveLocationPolicy.Remedy) {
        Task { @MainActor in
            // 从完成提示框里点的:等它退场再弹选择器或确认框,不然系统可能不弹。
            try? await Task.sleep(for: .milliseconds(450))
            switch remedy {
            case .grantFolderAccess:
                showFolderAccessPicker = true
            case .embedThisSong, .embedAllSongs:
                pendingEmbedRemedy = remedy
            }
        }
    }

    private func handleFolderAccessPick(_ result: Result<URL, any Error>) {
        switch result {
        case .success(let folderURL):
            Task {
                do {
                    try await sourceManager.grantFolderAccess(for: song, folderURL: folderURL)
                } catch {
                    dismissesAfterError = true
                    errorMessage = error.localizedDescription
                    return
                }
                await saveAgainAfterRemedy(grantedFolder: true)
            }
        case .failure(let error):
            guard !OperationCancellationPolicy.isCancellation(error) else {
                dismiss()
                return
            }
            dismissesAfterError = true
            errorMessage = error.localizedDescription
        }
    }

    /// 授权或改了保存方式之后重新探测,把刚才只存在 Primuse 的歌词再写一次。歌词已经存进
    /// Primuse 了,这次再出错就在报错之后关掉编辑器。
    private func saveAgainAfterRemedy(grantedFolder: Bool) async {
        completionRemedies = []
        cancelWritebackProbe()
        target = .checking
        if grantedFolder {
            // 授权之后旁边原有的歌词文件也看得见了:重拍来源快照,不然会被当成来源被别处改过。
            sourceSnapshot = await LyricsWriteback.currentSourceSnapshot(for: song, sourceManager: sourceManager)
        }
        dismissesAfterError = true
        await save(allowRemoval: false)
    }
}
