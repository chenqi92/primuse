import SwiftUI
import PrimuseKit

/// 歌词编辑的独立入口。跟「编辑标签」平级 —— 调歌词是高频且自成一件事的操作，
/// 不该埋在标签编辑器里再点一层。
///
/// 内容直接复用 `LyricsEditorView`(文本 / 打轴双模式)，这一层只负责把歌词
/// 读进来、把编辑结果写回去，以及处理"清空歌词需要二次确认"这个破坏性分支。
struct LyricsEditorSheet: View {
    let song: Song
    var autoStartsAudioTranscription = false
    var onSave: ((Song) -> Void)?

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
    @State private var mode: LyricsWriteback.Mode = .checking
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var completionMessage: String?
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
                        .allowsStructuredOnlyTranslationEditing(for: initialLines, mode: mode)
                ) { committed, lines in
                    handleCommit(committed, structuredLines: lines)
                }
                .overlay {
                    if isSaving { savingOverlay }
                }
            }
        }
        .task(id: song.id) { await load() }
        .alert(
            String(localized: "tag_editor_lyrics_error_title"),
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button(String(localized: "done"), role: .cancel) {}
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
            Button(String(localized: "done")) { dismiss() }
        } message: {
            Text(completionMessage ?? "")
        }
        .confirmationDialog(
            String(localized: "tag_editor_lyrics_delete_confirm_title"),
            isPresented: $pendingRemoval,
            titleVisibility: .visible
        ) {
            Button(String(localized: "tag_editor_lyrics_delete"), role: .destructive) {
                Task { await save(allowRemoval: true) }
            }
            Button(String(localized: "cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "tag_editor_lyrics_delete_confirm_message"))
        }
    }

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("tag_editor_lyrics_writeback_checking")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #if os(macOS)
        .frame(width: 820, height: 680)
        .background(PMColor.bg)
        #endif
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
        let loaded = await LyricsWriteback.loadEditablePayload(
            for: song,
            sourceManager: sourceManager
        )
        mode = await LyricsWriteback.resolveMode(
            for: song,
            sourceManager: sourceManager,
            sourcesStore: sourcesStore
        ).protectingSourceConflict(loaded.hasSourceConflict)
        text = loaded.text
        originalText = loaded.text
        initialLines = loaded.structuredLines
        pendingStructuredLines = nil
        sourceSnapshot = loaded.sourceSnapshot
        cacheSnapshot = loaded.cacheSnapshot
        isLoading = false
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
        let outcome = await LyricsWriteback.save(
            text: text,
            for: song,
            mode: mode,
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
        if outcome.persistence == .localOnly {
            let base = String(localized: "tag_editor_lyrics_writeback_read_only")
            if case .localOnly(let reason) = mode, let reason {
                completionMessage = [base, reason].joined(separator: "\n")
            } else {
                completionMessage = base
            }
            return
        }
        dismiss()
    }
}
