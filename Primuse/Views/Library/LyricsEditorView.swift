import SwiftUI
import PrimuseKit
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// 歌词编辑器。把“整理文本”和“逐句打轴”拆成两个任务模式；LRC/ELRC 源码
/// 仍保留为进阶入口，避免把格式细节摆在主流程里。
///
/// 真相仍然是 `text` 这个字符串 ── 保存 / 校验 / 写回音乐源的整条链路都在
/// `TagEditorView` 里以文本为单位工作,这里只是它的一个结构化视图层:进入时
/// 解析,完成时序列化写回。**没有实际编辑就不回写**,否则光是打开再关闭就会
/// 把 `[00:12.30]` 规范化成 `[00:12.300]`,让标签编辑器误以为有改动。
struct LyricsEditorView: View {
    let song: Song
    @Binding var text: String
    /// 非 nil 时，「完成」把序列化结果交给它而不是自己 dismiss —— 独立入口
    /// 需要先落盘(可能失败/需确认)再决定关不关。
    let onCommit: ((String) -> Void)?

    @Environment(AudioPlayerService.self) private var player
    @Environment(MusicLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss

    @State private var document: LyricsEditorDocument
    @State private var originalDocument: LyricsEditorDocument
    @State private var mode: Mode = .text
    @State private var sourceText: String
    @State private var sourceBaselineText = ""
    @State private var showSourceEditor = false
    @State private var playbackTime: TimeInterval = 0
    @State private var timingSession: LyricsTimingSession
    /// 文本模式中展开微调的逐字单元。用行 UUID 而不是下标，拖动排序后仍指向
    /// 同一行。
    @State private var selectedTextSyllable: SyllableSelection?
    /// 打轴模式在逐字行内的游标；行级歌词保持 nil，继续走原有逐句流程。
    @State private var timingSyllableIndex: Int?
    /// 打轴页进入时跟随当前播放句；用户手动前后切换或打点后暂停跟随，避免游标
    /// 在手指操作期间被播放进度抢走。
    @State private var timingFollowsPlayback = false
    @State private var showShiftPanel = false
    @State private var showUnstampedWarning = false
    /// 整体偏移用"基线 + 待定量"模型:每次都从基线重算,而不是在当前值上累加。
    /// 累加式在负向撞到 0 被 clamp 后就回不去了。
    @State private var shiftBaseline: LyricsEditorDocument?
    @State private var pendingShift: TimeInterval = 0
    /// 时间戳折叠开关。收起后就是纯文本,理词和读起来都清爽 ——
    /// 打轴模式下强制展开,否则看不见自己打到哪了。
    @State private var showTimestamps = true
    /// 粘贴后的拆句预览。非 nil 时占满整屏,让用户先确认拆得对不对再落库。
    @State private var pasteDraft: LyricsTextTools.SplitResult?
    /// 边听边写。歌在放,打字 + 回车即记时间戳。
    @State private var isLiveWriting = false
    @State private var liveDraft = ""
    @State private var showClearConfirm = false

    @FocusState private var focusedLine: UUID?
    @FocusState private var liveDraftFocused: Bool

    enum Mode { case timing, text }

    private struct SyllableSelection: Hashable {
        let lineID: UUID
        let index: Int
    }

    private struct TimingWordContext {
        let lineIndex: Int
        let syllableIndex: Int
        let syllables: [LyricSyllable]

        var current: LyricSyllable { syllables[syllableIndex] }
        var previous: LyricSyllable? {
            syllableIndex > 0 ? syllables[syllableIndex - 1] : nil
        }
        var next: LyricSyllable? {
            syllableIndex + 1 < syllables.count ? syllables[syllableIndex + 1] : nil
        }
    }

    init(song: Song, text: Binding<String>, onCommit: ((String) -> Void)? = nil) {
        self.song = song
        self._text = text
        self.onCommit = onCommit
        let parsed = LyricsEditorDocument(parsing: text.wrappedValue)
        _document = State(initialValue: parsed)
        _originalDocument = State(initialValue: parsed)
        _sourceText = State(initialValue: text.wrappedValue)
        _timingSession = State(initialValue: LyricsTimingSession(document: parsed))
    }

    var body: some View {
        content
            .task(id: song.id) { await trackPlaybackTime() }
    }

    // MARK: - 容器

    private var content: some View {
        #if os(macOS)
        macContainer
        #else
        iosContainer
        #endif
    }

    #if !os(macOS)
    private var iosContainer: some View {
        NavigationStack {
            VStack(spacing: 0) {
                iosHeader
                Divider()
                editorStack
            }
            .toolbar(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button(String(localized: "done")) { focusedLine = nil }
                }
            }
            .navigationDestination(isPresented: $showSourceEditor) {
                sourceEditorPage
            }
        }
        .interactiveDismissDisabled()
        .confirmationDialog(
            String(localized: "lyrics_editor_unstamped_warning_title"),
            isPresented: $showUnstampedWarning,
            titleVisibility: .visible
        ) { unstampedWarningActions } message: { unstampedWarningMessage }
        .sheet(isPresented: $showShiftPanel) { shiftPanel }
    }

    private var iosHeader: some View {
        HStack(spacing: 10) {
            Button(String(localized: "cancel")) { dismiss() }
                .font(.subheadline)
                .frame(minWidth: 54, alignment: .leading)

            Spacer(minLength: 0)
            compactModeSwitch
                .frame(width: 150)
            Spacer(minLength: 0)

            HStack(spacing: 13) {
                editorActionsMenu
                Button(String(localized: "done")) { requestCommit() }
                    .font(.subheadline.weight(.semibold))
            }
            .frame(minWidth: 72, alignment: .trailing)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.accentColor)
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }
    #endif

    #if os(macOS)
    private var macContainer: some View {
        VStack(spacing: 0) {
            macTitleBar
                .fixedSize(horizontal: false, vertical: true)
            Rectangle().fill(PMColor.divider).frame(height: 0.5)
            HStack(spacing: 0) {
                macModeRail
                Rectangle().fill(PMColor.divider).frame(width: 0.5)
                editorStack
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxHeight: .infinity)
            .clipped()
            Rectangle().fill(PMColor.divider).frame(height: 0.5)
            macFooter
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 820, height: 680)
        .background(PMColor.bg)
        .foregroundStyle(PMColor.text)
        .confirmationDialog(
            String(localized: "lyrics_editor_unstamped_warning_title"),
            isPresented: $showUnstampedWarning,
            titleVisibility: .visible
        ) { unstampedWarningActions } message: { unstampedWarningMessage }
        .sheet(isPresented: $showShiftPanel) { shiftPanel }
        .sheet(isPresented: $showSourceEditor) { sourceEditorSheet }
    }

    private var macTitleBar: some View {
        HStack(spacing: PMSpace.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "lyrics_editor_title"))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(PMColor.text)
                Text(
                    "\(song.title) · \(library.artistDisplayName(for: song) ?? String(localized: "unknown_artist"))"
                )
                    .font(PMFont.caption)
                    .foregroundStyle(PMColor.textMuted)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                openSourceEditor()
            } label: {
                Label(
                    String(localized: "lyrics_editor_mode_source"),
                    systemImage: "chevron.left.forwardslash.chevron.right"
                )
                .font(PMFont.bodyM)
                .foregroundStyle(PMColor.textMuted)
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(PMColor.glassBtn, in: .rect(cornerRadius: PMRadius.s))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, PMSpace.m16)
        .padding(.vertical, PMSpace.s10)
    }

    private var macModeRail: some View {
        VStack(alignment: .leading, spacing: PMSpace.s) {
            macModeButton(.text, systemImage: "text.alignleft")
            macModeButton(.timing, systemImage: "stopwatch")

            Rectangle().fill(PMColor.divider).frame(height: 0.5)
                .padding(.vertical, PMSpace.s)

            Text(String(
                format: String(localized: "lyrics_editor_line_summary %lld %lld"),
                document.lines.count,
                document.stampedCount
            ))
            .font(PMFont.caption)
            .foregroundStyle(PMColor.textMuted)

            if skippedTimingLineCount > 0 {
                Text(String(
                    format: String(localized: "lyrics_editor_timing_skipped_info %lld"),
                    skippedTimingLineCount
                ))
                .font(PMFont.captionS)
                .foregroundStyle(PMColor.textFaint)
            }

            Spacer()
        }
        .padding(PMSpace.m14)
        .frame(width: 156)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(PMColor.bgElev.opacity(0.56))
    }

    private func macModeButton(_ target: Mode, systemImage: String) -> some View {
        Button {
            modeBinding.wrappedValue = target
        } label: {
            Label(
                String(localized: target == .text ? "lyrics_editor_mode_text" : "lyrics_editor_mode_timing"),
                systemImage: systemImage
            )
            .font(PMFont.bodyM)
            .foregroundStyle(mode == target ? PMColor.text : PMColor.textMuted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(
                mode == target ? PMColor.brand.opacity(0.18) : Color.clear,
                in: .rect(cornerRadius: PMRadius.m)
            )
            .overlay {
                RoundedRectangle(cornerRadius: PMRadius.m, style: .continuous)
                    .strokeBorder(mode == target ? PMColor.brand.opacity(0.45) : Color.clear, lineWidth: 0.5)
            }
        }
        .buttonStyle(.plain)
    }

    private var macFooter: some View {
        HStack(spacing: PMSpace.s10) {
            stampProgressLabel
            Spacer()
            Button(String(localized: "cancel")) { dismiss() }
                .font(PMFont.bodyM)
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .padding(.horizontal, 14)
                .frame(height: 26)

            Button {
                requestCommit()
            } label: {
                Text(String(localized: "done"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(height: 26)
                    .padding(.horizontal, 16)
                    .background(PMColor.brand, in: .rect(cornerRadius: PMRadius.s))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, PMSpace.l24)
        .padding(.vertical, PMSpace.m)
    }
    #endif

    private var editorStack: some View {
        VStack(spacing: 0) {
            if let draft = pasteDraft {
                // 拆句预览是一次性的中间态：确认之前不显示常规编辑器，
                // 免得用户以为已经落库了。
                pasteReviewStack(draft)
            } else if isLiveWriting {
                liveWritingStack
            } else if document.lines.isEmpty {
                emptyLyricsStack
            } else {
                switch mode {
                case .timing:
                    timingStack
                case .text:
                    textModeStack
                }
            }
        }
        .confirmationDialog(
            String(localized: "lyrics_editor_clear_confirm_title"),
            isPresented: $showClearConfirm,
            titleVisibility: .visible
        ) {
            Button(String(localized: "lyrics_editor_clear_all"), role: .destructive) {
                document = LyricsEditorDocument()
                sourceText = ""
            }
            Button(String(localized: "cancel"), role: .cancel) {}
        }
    }

    // MARK: - 零歌词空状态

    /// 完全没歌词时不给一个空白输入框 —— 那等于把「从哪开始」的问题丢回给用户。
    /// 给三条具体的路：剪贴板里现成的、边听边写、或者去在线匹配。
    private var emptyLyricsStack: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 20)

            VStack(spacing: 12) {
                Image(systemName: "text.badge.xmark")
                    .font(.system(size: 38))
                    .foregroundStyle(.secondary)
                    .frame(width: 84, height: 84)
                    .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 24, style: .continuous))

                Text("lyrics_editor_empty_title")
                    .font(.title3.weight(.semibold))

                Text(
                    "\(song.title) · \(library.artistDisplayName(for: song) ?? String(localized: "unknown_artist"))"
                )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Text("lyrics_editor_empty_subtitle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 30)

            Spacer(minLength: 20)

            VStack(spacing: 10) {
                emptyOption(
                    icon: "doc.on.clipboard.fill",
                    title: String(localized: "lyrics_editor_paste_replace"),
                    subtitle: String(localized: "lyrics_editor_empty_paste_detail")
                ) {
                    pasteReplace()
                }

                emptyOption(
                    icon: "mic.fill",
                    title: String(localized: "lyrics_editor_empty_live"),
                    subtitle: String(localized: "lyrics_editor_empty_live_detail")
                ) {
                    startLiveWriting()
                }

                emptyOption(
                    icon: "square.and.pencil",
                    title: String(localized: "lyrics_editor_empty_manual"),
                    subtitle: String(localized: "lyrics_editor_empty_manual_detail")
                ) {
                    mode = .text
                    let id = document.insertLine(at: 0)
                    focusedLine = id
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
    }

    /// 剪贴板里像歌词的一段文字。只在用户明确点「粘贴」后读取，
    /// 避免进入编辑器时触发系统剪贴板权限提示。
    @State private var clipboardPreview: LyricsTextTools.SplitResult?

    private func readClipboardPreview() -> LyricsTextTools.SplitResult? {
        #if os(iOS)
        guard UIPasteboard.general.hasStrings, let text = UIPasteboard.general.string else {
            return nil
        }
        #elseif os(macOS)
        guard let text = NSPasteboard.general.string(forType: .string) else {
            return nil
        }
        #else
        let text = ""
        #endif
        let result = LyricsTextTools.splitIntoLines(text)
        // 一两行的剪贴板内容多半不是歌词(复制的歌名/链接)，别误导用户。
        return result.lines.count >= 3 ? result : nil
    }

    private func emptyOption(
        icon: String,
        title: String,
        subtitle: String,
        prominent: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 13) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                    .foregroundStyle(prominent ? Color.accentColor : .secondary)
                    .frame(width: 26)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.subheadline.weight(prominent ? .semibold : .medium))
                        .foregroundStyle(prominent ? Color.accentColor : .primary)
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }

                Spacer(minLength: 4)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(prominent ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
            }
            .padding(15)
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(prominent ? Color.accentColor.opacity(0.10) : Color.secondary.opacity(0.08))
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(
                                prominent ? Color.accentColor.opacity(0.45) : Color.secondary.opacity(0.14),
                                lineWidth: prominent ? 1 : 0.5
                            )
                    }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    // MARK: - 粘贴拆句预览

    /// 粘完先看拆得对不对再进下一步。自动做掉的事(合并空行、去版权行)明写出来，
    /// 用户才知道少的那几行去哪了。
    private func pasteReviewStack(_ draft: LyricsTextTools.SplitResult) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 19))
                    .foregroundStyle(Color.accentColor)

                VStack(alignment: .leading, spacing: 3) {
                    Text(String(
                        format: String(localized: "lyrics_editor_paste_parsed %lld"),
                        draft.lines.count
                    ))
                    .font(.subheadline.weight(.medium))

                    if draft.removedBlankRuns > 0 || !draft.droppedCreditLines.isEmpty {
                        Text(pasteAdjustmentSummary(draft))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 10)

            List {
                ForEach(Array(draft.lines.enumerated()), id: \.offset) { index, line in
                    HStack(spacing: 11) {
                        Text("\(index + 1)")
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 22, alignment: .trailing)
                        Text(line)
                            .font(.system(size: 13.5))
                            .lineLimit(2)
                    }
                    .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                }
                .onDelete { offsets in
                    var lines = draft.lines
                    for index in offsets.sorted(by: >) where lines.indices.contains(index) {
                        lines.remove(at: index)
                    }
                    pasteDraft = LyricsTextTools.SplitResult(
                        lines: lines,
                        removedBlankRuns: draft.removedBlankRuns,
                        droppedCreditLines: draft.droppedCreditLines
                    )
                }
            }
            .listStyle(.plain)

            Divider()

            HStack(spacing: 10) {
                Button {
                    pasteDraft = nil
                } label: {
                    Label(String(localized: "lyrics_editor_paste_redo"), systemImage: "arrow.counterclockwise")
                        .font(.subheadline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.bordered)
                .clipShape(Capsule())

                Button {
                    acceptPasteDraft(draft)
                } label: {
                    Label(String(localized: "lyrics_editor_paste_accept"), systemImage: "checkmark")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .clipShape(Capsule())
                .disabled(draft.lines.isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

    private func pasteAdjustmentSummary(_ draft: LyricsTextTools.SplitResult) -> String {
        var parts: [String] = []
        if draft.removedBlankRuns > 0 {
            parts.append(String(
                format: String(localized: "lyrics_editor_paste_merged_blanks %lld"),
                draft.removedBlankRuns
            ))
        }
        if !draft.droppedCreditLines.isEmpty {
            parts.append(String(
                format: String(localized: "lyrics_editor_paste_dropped_credits %lld"),
                draft.droppedCreditLines.count
            ))
        }
        return parts.joined(separator: " · ")
    }

    private func acceptPasteDraft(_ draft: LyricsTextTools.SplitResult) {
        let pasted = LyricsEditorDocument(parsing: draft.lines.joined(separator: "\n"))
        if pasted.stampedCount > 0 || !pasted.metadataLines.isEmpty {
            // 已经是 LRC / ELRC 时沿用其中的时间轴和元数据；把整行当纯文本再打轴
            // 会写出 `[新时间][原时间]正文`，播放侧会展开成重复歌词。
            document = pasted
        } else {
            document = LyricsEditorDocument(
                metadataLines: document.metadataLines,
                lines: pasted.lines
            )
        }
        sourceText = document.serialized()
        pasteDraft = nil
        mode = .text
    }

    // MARK: - 边听边写

    /// 歌在放，用户只管打字；按回车的那一刻把当前播放时间记成这句的时间戳。
    /// 写完一首，歌词和时间轴同时完成，不用再单独打一遍轴。
    private var liveWritingStack: some View {
        VStack(spacing: 0) {
            transportBar
            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(document.lines.enumerated()), id: \.element.id) { index, line in
                            HStack(alignment: .firstTextBaseline, spacing: 11) {
                                Text(line.timestamp.map(timeLabel) ?? "—")
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .foregroundStyle(Color.accentColor)
                                Text(line.text)
                                    .font(.system(size: 14.5))
                                    .lineLimit(2)
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 5)
                            .id(index)
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: document.lines.count) { _, count in
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(max(0, count - 1), anchor: .bottom)
                    }
                }
            }

            Divider()

            VStack(spacing: 8) {
                HStack(spacing: 11) {
                    Text(timeLabel(playbackTime))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()

                    TextField(
                        String(localized: "lyrics_editor_live_placeholder"),
                        text: $liveDraft
                    )
                    .textFieldStyle(.plain)
                    .font(.system(size: 15, weight: .medium))
                    .focused($liveDraftFocused)
                    .submitLabel(.next)
                    .onSubmit { commitLiveLine() }
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 11)
                .background {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.secondary.opacity(0.08))
                        .overlay {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(Color.accentColor.opacity(0.5), lineWidth: 1)
                        }
                }

                HStack {
                    Text("lyrics_editor_live_hint")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        undoLiveLine()
                    } label: {
                        Label(String(localized: "lyrics_editor_live_undo"), systemImage: "arrow.uturn.backward")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(document.lines.isEmpty ? .secondary : Color.accentColor)
                    .disabled(document.lines.isEmpty)

                    Button(String(localized: "done")) {
                        finishLiveWriting()
                    }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

    private func startLiveWriting() {
        isLiveWriting = true
        liveDraft = ""
        if isLinkedToPlayback {
            if !player.isPlaying { player.resume() }
        } else {
            Task { await player.play(song: song) }
        }
        liveDraftFocused = true
    }

    /// 回车 = 这句从当前播放位置开始。用 `interpolatedTime()` 而不是 `currentTime`，
    /// 后者是 0.5s 采样，直接拿来记会系统性偏早。
    private func commitLiveLine() {
        let text = liveDraft.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        let stamp = isLinkedToPlayback ? player.interpolatedTime() : playbackTime
        document.lines.append(EditableLyricLine(timestamp: max(0, stamp), text: text))
        liveDraft = ""
        liveDraftFocused = true
    }

    /// 写错了退回上一句 —— 把它的文字放回输入框，改完再回车。
    private func undoLiveLine() {
        guard let last = document.lines.popLast() else { return }
        liveDraft = last.text
        liveDraftFocused = true
    }

    private func finishLiveWriting() {
        // 输入框里还剩半句时一并收下，别让用户白打。
        let pending = liveDraft.trimmingCharacters(in: .whitespaces)
        if !pending.isEmpty { commitLiveLine() }
        isLiveWriting = false
        liveDraftFocused = false
        sourceText = document.serialized()
        mode = .text
    }

    // MARK: - 整篇文本操作

    private var textModeStack: some View {
        #if os(macOS)
        macTextStack
        #else
        iosTextStack
        #endif
    }

    #if !os(macOS)
    private var iosTextStack: some View {
        VStack(spacing: 0) {
            textDocumentHeader
            editableLineScroll
            textActionStrip

            Button {
                modeBinding.wrappedValue = .timing
            } label: {
                Label(String(localized: "lyrics_editor_tap_sync"), systemImage: "stopwatch")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
                    .background(Color.accentColor.opacity(0.10), in: .rect(cornerRadius: 10))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.accentColor.opacity(0.72), lineWidth: 1)
                    }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 12)
        }
    }

    private var textDocumentHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(song.title)
                .font(.headline)
                .lineLimit(1)

            Text(
                "\(library.artistDisplayName(for: song) ?? String(localized: "unknown_artist")) · \(String(format: String(localized: "lyrics_editor_line_summary %lld %lld"), document.lines.count, document.stampedCount))"
            )
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            HStack(spacing: 10) {
                Label(String(localized: "lyrics_editor_reorder_hint"), systemImage: "line.3.horizontal")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Spacer()

                if !document.isMonotonic {
                    Button {
                        document.sortByTimestamp()
                    } label: {
                        Label(String(localized: "lyrics_editor_sort"), systemImage: "arrow.up.arrow.down")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.orange)
                    }
                    .buttonStyle(.plain)
                }

                timestampToggle
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }
    #endif

    #if os(macOS)
    private var macTextStack: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: PMSpace.s10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(String(localized: "lyrics_editor_mode_text"))
                        .font(PMFont.sectionTitle)
                        .foregroundStyle(PMColor.text)
                    Text(String(localized: "lyrics_editor_reorder_hint"))
                        .font(PMFont.caption)
                        .foregroundStyle(PMColor.textMuted)
                }
                Spacer()
                if !document.isMonotonic {
                    Button {
                        document.sortByTimestamp()
                    } label: {
                        Label(String(localized: "lyrics_editor_sort"), systemImage: "arrow.up.arrow.down")
                            .foregroundStyle(PMColor.warn)
                    }
                    .buttonStyle(.plain)
                }
                timestampToggle
            }
            .padding(.horizontal, PMSpace.l24)
            .padding(.vertical, PMSpace.m14)

            editableLineScroll
                .padding(.horizontal, PMSpace.l24)

            HStack(spacing: PMSpace.s8) {
                textToolButton(
                    titleKey: "lyrics_editor_paste_replace",
                    systemImage: "doc.on.clipboard"
                ) { pasteReplace() }
                textToolButton(
                    titleKey: "lyrics_editor_resplit",
                    systemImage: "text.append",
                    enabled: document.stampedCount == 0 && !document.lines.isEmpty
                ) { resplitLines() }
                textToolButton(
                    titleKey: "lyrics_editor_drop_blanks",
                    systemImage: "wand.and.rays",
                    enabled: document.lines.contains {
                        $0.text.trimmingCharacters(in: .whitespaces).isEmpty
                    }
                ) { dropBlankLines() }
                Button {
                    insertLine(after: document.lines.count - 1)
                } label: {
                    Label(String(localized: "lyrics_editor_add_line"), systemImage: "plus")
                        .font(PMFont.bodyM)
                        .frame(maxWidth: .infinity)
                        .frame(height: 34)
                        .background(PMColor.glassBtn, in: .rect(cornerRadius: PMRadius.m))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, PMSpace.l24)
            .padding(.vertical, PMSpace.m14)
        }
    }
    #endif

    private var textActionStrip: some View {
        HStack(spacing: 8) {
            textToolButton(
                titleKey: "lyrics_editor_paste_replace",
                systemImage: "doc.on.clipboard"
            ) { pasteReplace() }
            textToolButton(
                titleKey: "lyrics_editor_resplit",
                systemImage: "text.append",
                enabled: document.stampedCount == 0 && !document.lines.isEmpty
            ) { resplitLines() }
            textToolButton(
                titleKey: "lyrics_editor_drop_blanks",
                systemImage: "wand.and.rays",
                enabled: document.lines.contains {
                    $0.text.trimmingCharacters(in: .whitespaces).isEmpty
                }
            ) { dropBlankLines() }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
    }

    private var timestampToggle: some View {
        Button {
            withAnimation(.easeOut(duration: 0.18)) { showTimestamps.toggle() }
        } label: {
            Label(
                String(localized: "lyrics_editor_show_timestamps"),
                systemImage: showTimestamps ? "checkmark.square.fill" : "square"
            )
            .font(.caption)
        }
        .buttonStyle(.plain)
        #if os(macOS)
        .foregroundStyle(PMColor.brand)
        #else
        .foregroundStyle(Color.accentColor)
        #endif
    }

    /// 文本模式顶部的三个整篇操作 + 时间戳折叠开关。
    private var textToolbar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                textToolButton(
                    titleKey: "lyrics_editor_paste_replace",
                    systemImage: "doc.on.clipboard"
                ) {
                    pasteReplace()
                }

                // 重新分行会把整篇拼回一段再拆，已打的轴必然对不上，
                // 所以打过轴之后就不给点了。
                textToolButton(
                    titleKey: "lyrics_editor_resplit",
                    systemImage: "text.append",
                    enabled: document.stampedCount == 0 && !document.lines.isEmpty
                ) {
                    resplitLines()
                }

                textToolButton(
                    titleKey: "lyrics_editor_drop_blanks",
                    systemImage: "wand.and.rays",
                    enabled: document.lines.contains {
                        $0.text.trimmingCharacters(in: .whitespaces).isEmpty
                    }
                ) {
                    dropBlankLines()
                }
            }

            HStack {
                Text(String(
                    format: String(localized: "lyrics_editor_line_summary %lld %lld"),
                    document.lines.count,
                    document.stampedCount
                ))
                .font(.caption2)
                .foregroundStyle(.secondary)

                Spacer()

                Button {
                    withAnimation(.easeOut(duration: 0.18)) { showTimestamps.toggle() }
                } label: {
                    Label(
                        String(localized: "lyrics_editor_show_timestamps"),
                        systemImage: showTimestamps ? "checkmark.square.fill" : "square"
                    )
                    .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func textToolButton(
        titleKey: String.LocalizationValue,
        systemImage: String,
        enabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(String(localized: titleKey), systemImage: systemImage)
                .font(.caption)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(Color.secondary.opacity(0.10), in: .rect(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
    }

    /// 用剪贴板整段替换。走跟空状态同一个预览，替换前用户还能反悔。
    private func pasteReplace() {
        guard let preview = readClipboardPreview() else {
            clipboardPreview = nil
            return
        }
        clipboardPreview = preview
        pasteDraft = preview
    }

    /// 重新分行 —— 把当前所有行拼回一整段再按标点拆。时间戳会因此失效，
    /// 所以只对没打过轴的文档开放。
    private func resplitLines() {
        let joined = document.lines.map(\.text).joined(separator: "\n")
        let result = LyricsTextTools.splitIntoLines(joined, dropCredits: false)
        guard !result.isEmpty else { return }
        pasteDraft = result
    }

    private func dropBlankLines() {
        let before = document.lines.count
        document.lines.removeAll { $0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        if document.lines.count != before { sourceText = document.serialized() }
    }

    private var compactModeSwitch: some View {
        HStack(spacing: 2) {
            compactModeButton(.timing)
            compactModeButton(.text)
        }
        .padding(3)
        .background(Color.secondary.opacity(0.10), in: .rect(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.14), lineWidth: 0.5)
        }
    }

    private func compactModeButton(_ target: Mode) -> some View {
        Button {
            modeBinding.wrappedValue = target
        } label: {
            Text(String(localized: target == .timing
                        ? "lyrics_editor_mode_timing"
                        : "lyrics_editor_mode_text"))
                .font(.subheadline.weight(mode == target ? .semibold : .regular))
                .foregroundStyle(mode == target ? Color.primary : Color.secondary)
                .frame(maxWidth: .infinity)
                .frame(height: 30)
                .background(
                    mode == target ? Color.secondary.opacity(0.16) : Color.clear,
                    in: .rect(cornerRadius: 7)
                )
        }
        .buttonStyle(.plain)
    }

    private var editorActionsMenu: some View {
        Menu {
            Button {
                openSourceEditor()
            } label: {
                Label(
                    String(localized: "lyrics_editor_mode_source"),
                    systemImage: "chevron.left.forwardslash.chevron.right"
                )
            }
            Button {
                insertLine(after: document.lines.count - 1)
            } label: {
                Label(String(localized: "lyrics_editor_add_line"), systemImage: "plus")
            }
            Button(role: .destructive) {
                if let selectedEditorLineIndex {
                    removeLine(at: selectedEditorLineIndex)
                }
            } label: {
                Label(String(localized: "lyrics_editor_remove_line"), systemImage: "minus")
            }
            .disabled(selectedEditorLineIndex == nil)
            Button {
                beginShiftAdjustment()
            } label: {
                Label(String(localized: "lyrics_editor_shift_all"), systemImage: "arrow.left.and.right")
            }
            .disabled(document.stampedCount == 0)
            if !document.isMonotonic {
                Button {
                    document.sortByTimestamp()
                } label: {
                    Label(String(localized: "lyrics_editor_sort"), systemImage: "arrow.up.arrow.down")
                }
            }
            Divider()
            Button(role: .destructive) {
                showClearConfirm = true
            } label: {
                Label(String(localized: "lyrics_editor_clear_all"), systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis")
                .frame(width: 28, height: 30)
                .contentShape(.rect)
        }
        .accessibilityLabel(String(localized: "lyrics_editor_more_actions"))
    }

    private var modeBinding: Binding<Mode> {
        Binding(
            get: { mode },
            set: { newMode in
                guard newMode != mode else { return }
                if newMode == .timing {
                    focusedLine = nil
                    prepareTimingSession()
                }
                withAnimation(.easeInOut(duration: 0.2)) { mode = newMode }
            }
        )
    }

    // MARK: - 播放联动

    private var isLinkedToPlayback: Bool { player.currentSong?.id == song.id }

    private var transportBar: some View {
        HStack(spacing: 12) {
            if isLinkedToPlayback {
                Button {
                    if player.isPlaying { player.pause() } else { player.resume() }
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 15))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)

                Button {
                    player.seek(to: max(0, playbackTime - 3))
                } label: {
                    Image(systemName: "gobackward.5").font(.system(size: 13))
                }
                .buttonStyle(.plain)

                scrubber

                Text(timeLabel(playbackTime))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            } else {
                Image(systemName: "play.slash")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text(String(localized: "lyrics_editor_not_playing"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(String(localized: "lyrics_editor_play_this_song")) {
                    Task { await player.play(song: song) }
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var scrubber: some View {
        let total = max(player.duration, 0.01)
        return GeometryReader { geo in
            let ratio = min(max(playbackTime / total, 0), 1)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.22))
                Capsule().fill(Color.accentColor).frame(width: geo.size.width * ratio)
            }
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 0).onEnded { value in
                    let target = (value.location.x / geo.size.width) * total
                    player.seek(to: min(max(0, target), total))
                }
            )
        }
        .frame(height: 4)
    }

    /// 100ms 一拍。用 `interpolatedTime()` 而不是 `currentTime` ── 后者是 0.5s
    /// 采样,直接拿去打轴会系统性偏早最多 500ms。只在值真的变了才写 state,
    /// 暂停时自然停更,不会白白触发重绘。
    private func trackPlaybackTime() async {
        while !Task.isCancelled {
            if isLinkedToPlayback {
                let now = player.interpolatedTime()
                if abs(now - playbackTime) > 0.02 {
                    playbackTime = now
                    if mode == .timing,
                       timingFollowsPlayback,
                       let index = timingLineIndex(at: now) {
                        if timingSession.cursorIndex != index {
                            _ = timingSession.select(index: index, document: document)
                        }
                        updateTimingSyllableSelection(for: index, at: now)
                    }
                }
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    // MARK: - 行列表

    private var activeIndex: Int? {
        isLinkedToPlayback ? document.activeLineIndex(at: playbackTime) : nil
    }

    /// 制作信息保留在文本模式中，但不是会被演唱的歌词，不进入打轴游标。
    private var timingEligibleIndices: [Int] {
        document.lines.indices.filter { isTimingEligibleLine(at: $0) }
    }

    private var timedEligibleCount: Int {
        timingEligibleIndices.lazy.filter { document.lines[$0].isStamped }.count
    }

    private var unstampedEligibleCount: Int {
        timingEligibleIndices.count - timedEligibleCount
    }

    private var skippedTimingLineCount: Int {
        document.lines.count - timingEligibleIndices.count
    }

    private var playbackTimingIndex: Int? {
        guard isLinkedToPlayback else { return nil }
        return timingLineIndex(at: playbackTime)
    }

    private func timingLineIndex(at time: TimeInterval) -> Int? {
        return timingEligibleIndices
            .compactMap { index -> (index: Int, time: TimeInterval)? in
                guard let timestamp = document.lines[index].timestamp,
                      timestamp <= time else { return nil }
                return (index, timestamp)
            }
            .max { lhs, rhs in
                lhs.time == rhs.time ? lhs.index < rhs.index : lhs.time < rhs.time
            }?
            .index
    }

    private var previousTimingIndex: Int? {
        guard let cursor = timingSession.cursorIndex,
              let position = timingEligibleIndices.firstIndex(of: cursor),
              position > timingEligibleIndices.startIndex else { return nil }
        return timingEligibleIndices[timingEligibleIndices.index(before: position)]
    }

    private var nextTimingIndex: Int? {
        guard let cursor = timingSession.cursorIndex,
              let position = timingEligibleIndices.firstIndex(of: cursor) else { return nil }
        let nextPosition = timingEligibleIndices.index(after: position)
        guard nextPosition < timingEligibleIndices.endIndex else { return nil }
        return timingEligibleIndices[nextPosition]
    }

    private var timingWordContext: TimingWordContext? {
        guard let lineIndex = timingSession.cursorIndex,
              document.lines.indices.contains(lineIndex),
              let syllables = document.lines[lineIndex].syllables,
              !syllables.isEmpty else { return nil }
        let index = min(max(timingSyllableIndex ?? 0, 0), syllables.count - 1)
        return TimingWordContext(
            lineIndex: lineIndex,
            syllableIndex: index,
            syllables: syllables
        )
    }

    private var canSelectPreviousTimingUnit: Bool {
        if let context = timingWordContext, context.syllableIndex > 0 { return true }
        return previousTimingIndex != nil
    }

    private var canSelectNextTimingUnit: Bool {
        if let context = timingWordContext,
           context.syllableIndex + 1 < context.syllables.count { return true }
        return nextTimingIndex != nil
    }

    private var canFineTuneTimingUnit: Bool {
        if let context = timingWordContext {
            return timingSession.canNudgeSyllable(
                in: document,
                lineIndex: context.lineIndex,
                syllableIndex: context.syllableIndex
            )
        }
        return timingSession.canNudge(in: document)
    }

    private func isTimingEligibleLine(at index: Int) -> Bool {
        guard document.lines.indices.contains(index) else { return false }
        let value = document.lines[index].text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return false }
        return !LyricsTextTools.isCreditLine(value) && !isSongHeader(value)
    }

    private func isTimingInformationLine(at index: Int) -> Bool {
        guard document.lines.indices.contains(index) else { return false }
        let value = document.lines[index].text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return false }
        return LyricsTextTools.isCreditLine(value) || isSongHeader(value)
    }

    private func isSongHeader(_ line: String) -> Bool {
        let title = song.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = (song.artistName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !artist.isEmpty else { return false }
        return line.localizedCaseInsensitiveContains(title)
            && line.localizedCaseInsensitiveContains(artist)
    }

    private var lineList: some View {
        List {
            ForEach(Array(document.lines.enumerated()), id: \.element.id) { index, line in
                lineRow(line: line, index: index)
                    .id(line.id)
                    .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
            }
            .onMove { document.moveLines(from: $0, to: $1) }
            .onDelete { document.removeLines(at: $0) }
        }
        .listStyle(.plain)
    }

    private var editableLineScroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(document.lines.enumerated()), id: \.element.id) { index, line in
                        lineRow(line: line, index: index)
                            .id(line.id)
                            .dropDestination(for: String.self) { items, _ in
                                guard let item = items.first else { return false }
                                return moveLine(withID: item, to: index)
                            }

                        if index < document.lines.count - 1 {
                            Divider().padding(.leading, showTimestamps ? 82 : 12)
                        }
                    }
                }
                .padding(.vertical, 5)
            }
            .onChange(of: focusedLine) { _, lineID in
                guard let lineID else { return }
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo(lineID, anchor: .center)
                }
            }
        }
        #if os(macOS)
        .background(PMColor.card, in: .rect(cornerRadius: PMRadius.l))
        .overlay {
            RoundedRectangle(cornerRadius: PMRadius.l, style: .continuous)
                .strokeBorder(PMColor.cardBorder, lineWidth: 0.5)
        }
        #else
        .background(Color.secondary.opacity(0.055), in: .rect(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.16), lineWidth: 0.5)
        }
        .padding(.horizontal, 16)
        #endif
    }

    private func lineRow(line: EditableLyricLine, index: Int) -> some View {
        let isActive = activeIndex == index

        return HStack(alignment: .top, spacing: 10) {
            if showTimestamps {
                timestampChip(line: line, index: index)
                    .frame(height: 28, alignment: .center)
            }

            lineTextContent(line: line, index: index)

            if isTimingInformationLine(at: index) {
                Image(systemName: "info.circle")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 28)
                    .help(String(localized: "lyrics_editor_timing_info_line"))
            }

            Button(role: .destructive) {
                removeLine(at: index)
            } label: {
                Image(systemName: "minus.circle")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 24, height: 28)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red)
            .accessibilityLabel(String(localized: "lyrics_editor_remove_line"))

            Image(systemName: "line.3.horizontal")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 28)
                .contentShape(.rect)
                .draggable(line.id.uuidString)
                .accessibilityLabel(String(localized: "lyrics_editor_reorder_line"))
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(rowBackground(isActive: isActive))
        }
        .contextMenu {
            Button(String(localized: "lyrics_editor_stamp_now")) { stampWithCurrentTime(index) }
                .disabled(!isLinkedToPlayback || isTimingInformationLine(at: index))
            if line.isStamped {
                Button(String(localized: "lyrics_editor_nudge_earlier")) { nudge(index, by: -0.1) }
                Button(String(localized: "lyrics_editor_nudge_later")) { nudge(index, by: 0.1) }
                Button(String(localized: "lyrics_editor_clear_stamp"), role: .destructive) {
                    document.clearStamp(at: index)
                }
            }
            Divider()
            Button(String(localized: "lyrics_editor_insert_below")) { insertLine(after: index) }
            Button(String(localized: "delete"), role: .destructive) {
                removeLine(at: index)
            }
        }
    }

    private func lineTextContent(line: EditableLyricLine, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField(
                String(localized: "lyrics_editor_line_placeholder"),
                text: textBinding(for: index),
                axis: .vertical
            )
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .frame(minHeight: 28, alignment: .center)
            .focused($focusedLine, equals: line.id)

            if let syllables = line.syllables, !syllables.isEmpty {
                wordTimingStrip(line: line, syllables: syllables)

                if let selection = selectedTextSyllable,
                   selection.lineID == line.id,
                   syllables.indices.contains(selection.index) {
                    selectedSyllableAdjustmentRow(
                        lineIndex: index,
                        syllableIndex: selection.index,
                        syllable: syllables[selection.index],
                        count: syllables.count
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func wordTimingStrip(
        line: EditableLyricLine,
        syllables: [LyricSyllable]
    ) -> some View {
        LyricsWordTimingFlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
            ForEach(Array(syllables.enumerated()), id: \.offset) { syllableIndex, syllable in
                let isSelected = selectedTextSyllable == SyllableSelection(
                    lineID: line.id,
                    index: syllableIndex
                )
                Button {
                    selectedTextSyllable = SyllableSelection(
                        lineID: line.id,
                        index: syllableIndex
                    )
                    if isLinkedToPlayback {
                        player.seek(to: syllable.start)
                    }
                } label: {
                    VStack(spacing: 2) {
                        Text(visibleSyllableText(syllable.text))
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(2)
                            .minimumScaleFactor(0.75)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                        Text(timeLabel(syllable.start))
                            .font(.system(size: 9, design: .monospaced))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .frame(minWidth: 44, maxWidth: 166)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(
                        isSelected ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.08),
                        in: .rect(cornerRadius: 6)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(
                                isSelected ? Color.accentColor.opacity(0.72) : Color.clear,
                                lineWidth: 1
                            )
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    "\(visibleSyllableText(syllable.text)), \(timeLabel(syllable.start))"
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(String(localized: "lyrics_editor_word_level_hint"))
    }

    private func selectedSyllableAdjustmentRow(
        lineIndex: Int,
        syllableIndex: Int,
        syllable: LyricSyllable,
        count: Int
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            Text("\(syllableIndex + 1)/\(count)")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
            Text(timeLabel(syllable.start))
                .font(.system(size: 10, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)

            syllableNudgeButton(
                systemImage: "minus",
                label: String(localized: "lyrics_editor_nudge_earlier")
            ) {
                nudgeTextSyllable(lineIndex: lineIndex, syllableIndex: syllableIndex, by: -0.1)
            }
            syllableNudgeButton(
                systemImage: "plus",
                label: String(localized: "lyrics_editor_nudge_later")
            ) {
                nudgeTextSyllable(lineIndex: lineIndex, syllableIndex: syllableIndex, by: 0.1)
            }
        }
        .frame(height: 26)
    }

    private func syllableNudgeButton(
        systemImage: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 30, height: 24)
                .background(Color.secondary.opacity(0.10), in: .rect(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func moveLine(withID rawID: String, to targetIndex: Int) -> Bool {
        guard let id = UUID(uuidString: rawID),
              let sourceIndex = document.lines.firstIndex(where: { $0.id == id }),
              document.lines.indices.contains(targetIndex) else { return false }
        guard sourceIndex != targetIndex else { return true }

        let selectedID = timingSession.cursorIndex.flatMap { index in
            document.lines.indices.contains(index) ? document.lines[index].id : nil
        }
        let destination = sourceIndex < targetIndex ? targetIndex + 1 : targetIndex
        document.moveLines(from: IndexSet(integer: sourceIndex), to: destination)
        let preferredIndex = selectedID.flatMap { selected in
            document.lines.firstIndex(where: { $0.id == selected })
        }
        timingSession.reset(document: document, preferredIndex: preferredIndex)
        return true
    }

    private func rowBackground(isActive: Bool) -> Color {
        if isActive { return Color.accentColor.opacity(0.10) }
        return .clear
    }

    @ViewBuilder
    private func timestampChip(line: EditableLyricLine, index: Int) -> some View {
        if let timestamp = line.timestamp {
            Button {
                player.seek(to: timestamp, startPlaying: true)
            } label: {
                Text(timeLabel(timestamp))
                    .font(.system(size: 11, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(isLinkedToPlayback ? Color.accentColor : .secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.secondary.opacity(0.12), in: .rect(cornerRadius: 4))
            }
            .buttonStyle(.plain)
            .disabled(!isLinkedToPlayback)
        } else if isTimingInformationLine(at: index) {
            Text(String(localized: "lyrics_editor_info_line_badge"))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.secondary.opacity(0.08), in: .rect(cornerRadius: 4))
        } else {
            Button {
                stampWithCurrentTime(index)
            } label: {
                Label(String(localized: "lyrics_editor_stamp"), systemImage: "stopwatch")
                    .font(.system(size: 10, weight: .medium))
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(isLinkedToPlayback ? Color.accentColor : .secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.secondary.opacity(0.08), in: .rect(cornerRadius: 4))
            }
            .buttonStyle(.plain)
            .disabled(!isLinkedToPlayback)
        }
    }

    private func textBinding(for index: Int) -> Binding<String> {
        Binding(
            get: {
                document.lines.indices.contains(index) ? document.lines[index].text : ""
            },
            set: { newValue in
                guard document.lines.indices.contains(index) else { return }
                if newValue != document.lines[index].text,
                   selectedTextSyllable?.lineID == document.lines[index].id {
                    selectedTextSyllable = nil
                }
                document.updateText(newValue, at: index)
            }
        )
    }

    private func nudgeTextSyllable(
        lineIndex: Int,
        syllableIndex: Int,
        by delta: TimeInterval
    ) {
        guard document.nudgeSyllable(
            at: lineIndex,
            syllableIndex: syllableIndex,
            by: delta
        ) != nil else { return }
        #if os(iOS)
        UISelectionFeedbackGenerator().selectionChanged()
        #endif
    }

    // MARK: - 底部工具条

    private var bottomBar: some View {
        VStack(spacing: 0) {
            Divider()

            HStack(spacing: 14) {
                Button {
                    insertLine(after: document.lines.count - 1)
                } label: {
                    Label(String(localized: "lyrics_editor_add_line"), systemImage: "plus")
                        .font(.caption)
                }
                .buttonStyle(.plain)

                Button {
                    beginShiftAdjustment()
                } label: {
                    Label(String(localized: "lyrics_editor_shift_all"), systemImage: "arrow.left.and.right")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .disabled(document.stampedCount == 0)

                if !document.isMonotonic {
                    Button {
                        document.sortByTimestamp()
                    } label: {
                        Label(String(localized: "lyrics_editor_sort"), systemImage: "arrow.up.arrow.down")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    .buttonStyle(.plain)
                }

                Button(role: .destructive) {
                    showClearConfirm = true
                } label: {
                    Label(String(localized: "lyrics_editor_clear_all"), systemImage: "trash")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red)

                Spacer()

                Button {
                    modeBinding.wrappedValue = .timing
                } label: {
                    Label(String(localized: "lyrics_editor_tap_sync"), systemImage: "stopwatch")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .disabled(document.lines.isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            HStack {
                stampProgressLabel
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
    }

    // MARK: - 专注打轴

    private var timingStack: some View {
        VStack(spacing: 0) {
            transportBar
            Divider()

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Text(String(
                        format: String(localized: "lyrics_editor_timing_progress %lld %lld"),
                        timedEligibleCount,
                        timingEligibleIndices.count
                    ))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                    if skippedTimingLineCount > 0 {
                        Text(String(
                            format: String(localized: "lyrics_editor_timing_skipped_info %lld"),
                            skippedTimingLineCount
                        ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }

                    if let context = timingWordContext {
                        Text("\(String(localized: "lyrics_word_level_badge")) \(context.syllableIndex + 1)/\(context.syllables.count)")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Color.accentColor)
                    }
                }
                .padding(.top, 18)

                Spacer(minLength: 12)
                timingLineContext
                Spacer(minLength: 18)

                HStack(spacing: 14) {
                    timingNavigationButton(
                        systemImage: "chevron.left",
                        label: String(localized: "lyrics_editor_previous_line"),
                        enabled: canSelectPreviousTimingUnit
                    ) { selectPreviousTimingUnit() }

                    Button {
                        stampTimingUnit()
                    } label: {
                        VStack(spacing: 5) {
                            Text(String(localized: timingWordContext == nil
                                        ? "lyrics_editor_mode_timing"
                                        : "lyrics_word_level_badge"))
                                .font(.system(size: 23, weight: .bold, design: .rounded))
                            Text(String(localized: timingWordContext == nil
                                        ? "lyrics_editor_timing_hint"
                                        : "lyrics_editor_word_level_hint"))
                                .font(.caption2)
                                .fontWeight(.medium)
                        }
                        .foregroundStyle(Color.accentColor)
                        .frame(maxWidth: 270)
                        .frame(height: 90)
                        .background(Color.accentColor.opacity(0.12), in: .rect(cornerRadius: 18))
                        .overlay {
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(Color.accentColor.opacity(0.82), lineWidth: 1.5)
                        }
                        .contentShape(.rect(cornerRadius: 18))
                    }
                    .buttonStyle(.plain)
                    .disabled(!isLinkedToPlayback || timingSession.cursorIndex == nil)
                    .opacity(isLinkedToPlayback && timingSession.cursorIndex != nil ? 1 : 0.48)

                    timingNavigationButton(
                        systemImage: "chevron.right",
                        label: String(localized: "lyrics_editor_next_line"),
                        enabled: canSelectNextTimingUnit
                    ) { selectNextTimingUnit() }
                }
                .padding(.horizontal, 22)

                HStack(spacing: 12) {
                    Button {
                        followPlaybackLine()
                    } label: {
                        Label(
                            String(localized: timingFollowsPlayback
                                   ? "lyrics_editor_following_playback"
                                   : "lyrics_editor_return_to_playback"),
                            systemImage: timingFollowsPlayback ? "location.fill" : "scope"
                        )
                        .font(.caption.weight(.medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(timingFollowsPlayback ? Color.accentColor : Color.secondary)
                    .disabled(!isLinkedToPlayback || playbackTimingIndex == nil)

                    Spacer()

                    timingHistoryButton(
                        systemImage: "arrow.uturn.backward",
                        label: String(localized: "lyrics_editor_timing_undo"),
                        enabled: timingSession.canUndo
                    ) { undoTimingChange() }

                    timingHistoryButton(
                        systemImage: "arrow.uturn.forward",
                        label: String(localized: "lyrics_editor_timing_redo"),
                        enabled: timingSession.canRedo
                    ) { redoTimingChange() }
                }
                .padding(.horizontal, 22)
                .padding(.top, 14)

                HStack(spacing: 8) {
                    timingFineTuneButton(
                        title: "− 0.1s",
                        accessibilityLabel: String(localized: "lyrics_editor_nudge_earlier")
                    ) {
                        nudgeTimingUnit(by: -0.1)
                    }

                    timingFineTuneButton(
                        title: "+ 0.1s",
                        accessibilityLabel: String(localized: "lyrics_editor_nudge_later")
                    ) {
                        nudgeTimingUnit(by: 0.1)
                    }

                    Button {
                        beginShiftAdjustment()
                    } label: {
                        Label(String(localized: "lyrics_editor_shift_all"), systemImage: "arrow.left.and.right")
                            .font(.caption.weight(.medium))
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            .background(Color.secondary.opacity(0.10), in: .rect(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    .disabled(document.stampedCount == 0)
                    .opacity(document.stampedCount == 0 ? 0.4 : 1)
                }
                .padding(.horizontal, 16)
                .padding(.top, 18)
                .padding(.bottom, 14)
            }
        }
        #if os(macOS)
        .padding(.horizontal, PMSpace.l24)
        .padding(.vertical, PMSpace.m14)
        #endif
    }

    @ViewBuilder
    private var timingLineContext: some View {
        if let context = timingWordContext {
            timingWordContextView(context)
        } else if let index = timingSession.cursorIndex, document.lines.indices.contains(index) {
            VStack(spacing: 20) {
                timingContextLine(at: previousTimingIndex, role: .previous)
                timingContextLine(at: index, role: .current)
                timingContextLine(at: nextTimingIndex, role: .next)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 28)
        } else {
            VStack(spacing: 10) {
                Image(systemName: timingEligibleIndices.isEmpty ? "info.circle" : "checkmark.circle.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(timingEligibleIndices.isEmpty ? Color.secondary : Color.green)
                Text(String(localized: timingEligibleIndices.isEmpty
                            ? "lyrics_editor_no_timing_lines"
                            : "lyrics_editor_all_stamped"))
                    .font(.title3.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 28)
        }
    }

    private func timingWordContextView(_ context: TimingWordContext) -> some View {
        VStack(spacing: 13) {
            Text(document.lines[context.lineIndex].text)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)

            HStack(alignment: .firstTextBaseline, spacing: 18) {
                timingWordUnit(context.previous, role: .previous)
                timingWordUnit(context.current, role: .current)
                timingWordUnit(context.next, role: .next)
            }
            .frame(maxWidth: .infinity, minHeight: 72)

            Text("\(context.syllableIndex + 1)/\(context.syllables.count) · \(timeLabel(context.current.start))")
                .font(.system(size: 11, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 158)
        .padding(.horizontal, 28)
    }

    private enum TimingLineRole: Equatable { case previous, current, next }

    private func timingWordUnit(
        _ syllable: LyricSyllable?,
        role: TimingLineRole
    ) -> some View {
        Text(syllable.map { visibleSyllableText($0.text) } ?? " ")
            .font(role == .current
                  ? .system(size: 32, weight: .bold)
                  : .system(size: 18, weight: .medium))
            .foregroundStyle(role == .current ? Color.accentColor : Color.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.65)
            .frame(maxWidth: role == .current ? 180 : 80)
            .opacity(syllable == nil ? 0 : 1)
    }

    @ViewBuilder
    private func timingContextLine(at index: Int?, role: TimingLineRole) -> some View {
        if let index, document.lines.indices.contains(index) {
            Text(document.lines[index].text.isEmpty
                 ? String(localized: "lyrics_editor_line_placeholder")
                 : document.lines[index].text)
                .font(role == .current
                      ? .system(size: 28, weight: .bold)
                      : .system(size: 17, weight: .medium))
                .foregroundStyle(role == .current ? Color.primary : Color.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(role == .current ? 3 : 2)
                .minimumScaleFactor(0.72)
                .frame(maxWidth: .infinity, minHeight: role == .current ? 70 : 24)
        } else {
            Color.clear.frame(height: role == .current ? 70 : 24)
        }
    }

    private func timingHistoryButton(
        systemImage: String,
        label: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 32, height: 30)
                .background(Color.secondary.opacity(0.10), in: .rect(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .accessibilityLabel(label)
    }

    private func timingNavigationButton(
        systemImage: String,
        label: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 54, height: 54)
                .background(Color.secondary.opacity(0.10), in: .rect(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.32)
        .accessibilityLabel(label)
    }

    private func timingFineTuneButton(
        title: String,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline)
                .monospacedDigit()
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(Color.secondary.opacity(0.10), in: .rect(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(!canFineTuneTimingUnit)
        .opacity(canFineTuneTimingUnit ? 1 : 0.4)
        .accessibilityLabel(accessibilityLabel)
    }

    private var stampProgressLabel: some View {
        Group {
            if unstampedEligibleCount > 0, timedEligibleCount > 0 {
                Label(
                    String(
                        format: String(localized: "lyrics_editor_partial_progress"),
                        timedEligibleCount,
                        timingEligibleIndices.count
                    ),
                    systemImage: "exclamationmark.triangle"
                )
                .foregroundStyle(.orange)
            } else if timedEligibleCount > 0 {
                Label(String(localized: "lyrics_editor_all_stamped"), systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            } else {
                Label(String(localized: "lyrics_editor_plain_text"), systemImage: "text.alignleft")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
    }

    // MARK: - LRC / ELRC 源码

    private func openSourceEditor() {
        let serialized = document.serialized()
        sourceText = serialized
        sourceBaselineText = serialized
        showSourceEditor = true
    }

    #if !os(macOS)
    private var sourceEditorPage: some View {
        TextEditor(text: $sourceText)
            .font(.system(size: 12, design: .monospaced))
            .padding(.horizontal, 8)
            .navigationTitle(String(localized: "lyrics_editor_mode_source"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "done")) { applySourceEditor() }
                }
            }
    }
    #else
    private var sourceEditorSheet: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(String(localized: "lyrics_editor_mode_source"))
                    .font(.system(size: 13.5, weight: .semibold))
                Spacer()
                Button(String(localized: "cancel")) { showSourceEditor = false }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("lyricsSourceEditorCancel")
                Button(String(localized: "done")) { applySourceEditor() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("lyricsSourceEditorDone")
            }
            .padding(.horizontal, 18)
            .frame(height: 56)

            Divider()
            TextEditor(text: $sourceText)
                .font(.system(size: 12, design: .monospaced))
                .padding(.horizontal, 8)
        }
        .frame(width: 560, height: 620)
    }
    #endif

    private func applySourceEditor() {
        guard sourceText != sourceBaselineText else {
            showSourceEditor = false
            return
        }
        document = LyricsEditorDocument(parsing: sourceText)
        selectedTextSyllable = nil
        prepareTimingSession()
        showSourceEditor = false
    }

    // MARK: - 整体偏移

    private func beginShiftAdjustment() {
        shiftBaseline = document
        pendingShift = 0
        showShiftPanel = true
    }

    private var shiftPanel: some View {
        let baseline = shiftBaseline ?? document
        let maxBackward = baseline.maximumBackwardShift

        return VStack(spacing: 16) {
            Text(String(localized: "lyrics_editor_shift_all"))
                .font(.headline)

            Text(String(localized: "lyrics_editor_shift_hint"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Text(String(format: "%+.2f s", pendingShift))
                .font(.system(size: 30, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())

            if let preview = baseline.lines.first(where: \.isStamped)?.timestamp {
                let shifted = max(0, preview + max(pendingShift, -maxBackward))
                Text("\(timeLabel(preview))  →  \(timeLabel(shifted))")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                ForEach([-1.0, -0.5, -0.1, 0.1, 0.5, 1.0], id: \.self) { step in
                    Button(String(format: "%+g", step)) {
                        applyShift(pendingShift + step)
                    }
                    .font(.system(size: 12, weight: .medium))
                    .buttonStyle(.bordered)
                }
            }

            Slider(
                value: Binding(get: { pendingShift }, set: { applyShift($0) }),
                in: -max(maxBackward, 0.01)...10
            )

            if pendingShift < -maxBackward {
                Label(String(localized: "lyrics_editor_shift_clamped"), systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            HStack(spacing: 12) {
                Button(String(localized: "cancel")) {
                    if let shiftBaseline { document = shiftBaseline }
                    showShiftPanel = false
                }
                .buttonStyle(.bordered)

                Button(String(localized: "done")) {
                    finishShiftAdjustment()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(minWidth: 320)
        #if os(macOS)
        .frame(width: 380)
        #else
        .presentationDetents([.medium])
        #endif
    }

    /// 每次都从基线重算,不在当前文档上累加 ── 撞到 0 被 clamp 之后仍能原样退回。
    private func applyShift(_ value: TimeInterval) {
        pendingShift = value
        guard let shiftBaseline else { return }
        document = shiftBaseline.shifted(by: value)
    }

    private func finishShiftAdjustment() {
        let preferredIndex = timingSession.cursorIndex
        timingSession.reset(document: document, preferredIndex: preferredIndex)
        shiftBaseline = nil
        showShiftPanel = false
    }

    // MARK: - 打轴动作

    private func stampWithCurrentTime(_ index: Int) {
        guard isLinkedToPlayback, isTimingEligibleLine(at: index) else { return }
        document.stamp(at: index, time: player.interpolatedTime())
    }

    private func prepareTimingSession() {
        let liveTime = isLinkedToPlayback ? player.interpolatedTime() : playbackTime
        let playbackIndex = isLinkedToPlayback ? timingLineIndex(at: liveTime) : nil
        let preferredIndex = playbackIndex
            ?? timingEligibleIndices.first(where: { !document.lines[$0].isStamped })
            ?? timingEligibleIndices.first
        timingSession.reset(document: document, preferredIndex: preferredIndex)
        if preferredIndex == nil {
            _ = timingSession.select(index: nil, document: document)
        }
        updateTimingSyllableSelection(
            for: preferredIndex,
            at: playbackIndex == preferredIndex ? liveTime : nil
        )
        timingFollowsPlayback = playbackIndex != nil
    }

    private func stampTimingUnit() {
        guard isLinkedToPlayback else { return }
        let now = player.interpolatedTime()

        if let context = timingWordContext {
            guard timingSession.stampSyllable(
                document: &document,
                lineIndex: context.lineIndex,
                syllableIndex: context.syllableIndex,
                time: now
            ) != nil else { return }
            timingFollowsPlayback = false
            selectNextTimingUnit()
        } else {
            guard let stampedIndex = timingSession.stamp(
                document: &document,
                time: now
            ) else { return }
            timingFollowsPlayback = false
            let next = timingEligibleIndices.first(where: { $0 > stampedIndex })
            _ = timingSession.select(index: next, document: document)
            updateTimingSyllableSelection(for: next)
        }
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        #endif
    }

    private func selectPreviousTimingUnit() {
        timingFollowsPlayback = false
        if let context = timingWordContext, context.syllableIndex > 0 {
            timingSyllableIndex = context.syllableIndex - 1
            return
        }
        guard let previousTimingIndex else { return }
        _ = timingSession.select(index: previousTimingIndex, document: document)
        updateTimingSyllableSelection(for: previousTimingIndex, preferLast: true)
    }

    private func selectNextTimingUnit() {
        timingFollowsPlayback = false
        if let context = timingWordContext,
           context.syllableIndex + 1 < context.syllables.count {
            timingSyllableIndex = context.syllableIndex + 1
            return
        }
        guard let nextTimingIndex else { return }
        _ = timingSession.select(index: nextTimingIndex, document: document)
        updateTimingSyllableSelection(for: nextTimingIndex)
    }

    private func followPlaybackLine() {
        let liveTime = isLinkedToPlayback ? player.interpolatedTime() : playbackTime
        guard let playbackTimingIndex = timingLineIndex(at: liveTime) else { return }
        timingFollowsPlayback = true
        _ = timingSession.select(index: playbackTimingIndex, document: document)
        updateTimingSyllableSelection(for: playbackTimingIndex, at: liveTime)
    }

    private func undoTimingChange() {
        timingFollowsPlayback = false
        guard let restoredLine = timingSession.undo(document: &document) else { return }
        if let syllableIndex = timingSession.affectedSyllableIndex {
            timingSyllableIndex = syllableIndex
        } else {
            updateTimingSyllableSelection(for: restoredLine)
        }
    }

    private func redoTimingChange() {
        timingFollowsPlayback = false
        guard let redone = timingSession.redo(document: &document) else { return }
        if let syllableIndex = timingSession.affectedSyllableIndex {
            timingSyllableIndex = syllableIndex
        } else {
            let next = timingEligibleIndices.first(where: { $0 > redone })
            _ = timingSession.select(index: next, document: document)
            updateTimingSyllableSelection(for: next)
        }
    }

    private func nudgeTimingUnit(by delta: TimeInterval) {
        timingFollowsPlayback = false
        let didNudge: Bool
        if let context = timingWordContext {
            didNudge = timingSession.nudgeSyllable(
                document: &document,
                lineIndex: context.lineIndex,
                syllableIndex: context.syllableIndex,
                by: delta
            ) != nil
        } else {
            didNudge = timingSession.nudge(document: &document, by: delta) != nil
        }
        guard didNudge else { return }
        #if os(iOS)
        UISelectionFeedbackGenerator().selectionChanged()
        #endif
    }

    private func updateTimingSyllableSelection(
        for lineIndex: Int?,
        at time: TimeInterval? = nil,
        preferLast: Bool = false
    ) {
        guard let lineIndex,
              document.lines.indices.contains(lineIndex),
              let syllables = document.lines[lineIndex].syllables,
              !syllables.isEmpty else {
            timingSyllableIndex = nil
            return
        }

        if let time {
            timingSyllableIndex = syllables.lastIndex(where: { $0.start <= time }) ?? 0
        } else {
            timingSyllableIndex = preferLast ? syllables.count - 1 : 0
        }
    }

    private func nudge(_ index: Int, by delta: TimeInterval) {
        // 上下文菜单弹出后行可能已被删,index 会失效。
        guard document.lines.indices.contains(index),
              let current = document.lines[index].timestamp else { return }
        document.stamp(at: index, time: max(0, current + delta))
    }

    private func insertLine(after index: Int) {
        let target = min(max(0, index + 1), document.lines.count)
        let id = document.insertLine(at: target)
        focusedLine = id
    }

    private var selectedEditorLineIndex: Int? {
        switch mode {
        case .timing:
            return timingSession.cursorIndex.flatMap {
                document.lines.indices.contains($0) ? $0 : nil
            }
        case .text:
            guard let focusedLine else { return nil }
            return document.lines.firstIndex { $0.id == focusedLine }
        }
    }

    private func removeLine(at index: Int) {
        guard document.lines.indices.contains(index) else { return }

        let removedID = document.lines[index].id
        let selectedID = timingSession.cursorIndex.flatMap { selectedIndex in
            document.lines.indices.contains(selectedIndex) ? document.lines[selectedIndex].id : nil
        }
        let fallbackID = timingEligibleIndices.first(where: { $0 > index }).map { document.lines[$0].id }
            ?? timingEligibleIndices.last(where: { $0 < index }).map { document.lines[$0].id }

        document.removeLines(at: IndexSet(integer: index))
        if focusedLine == removedID { focusedLine = nil }
        if selectedTextSyllable?.lineID == removedID { selectedTextSyllable = nil }

        let preferredID = selectedID == removedID ? fallbackID : selectedID
        let preferredIndex = preferredID.flatMap { id in
            document.lines.firstIndex { $0.id == id }
        }
        timingSession.reset(document: document, preferredIndex: preferredIndex)
        if timingEligibleIndices.isEmpty {
            _ = timingSession.select(index: nil, document: document)
        }
        timingFollowsPlayback = false
    }

    // MARK: - 提交

    /// 部分打轴的文档存下去会掉行 ── `LyricsContentParser.parseText` 一旦发现
    /// 存在带时间戳的行,就只返回那些行,未打轴的会被静默丢弃。所以这里拦一道。
    private var willDropUnstampedLines: Bool {
        timedEligibleCount > 0 && unstampedEligibleCount > 0
    }

    private func requestCommit() {
        if willDropUnstampedLines {
            showUnstampedWarning = true
            return
        }
        commit()
    }

    private func commit() {
        let preparedDocument = document.preparedForTimingCommit(
            eligibleIndices: timingEligibleIndices
        )
        let committedText = preparedDocument.committedText(
            preserving: text,
            comparedTo: originalDocument
        )
        // 没改就不回写,免得规范化后的文本让标签编辑器误判有改动。
        let preparedHasEdits = !preparedDocument.hasSameContent(as: originalDocument)
        if preparedHasEdits {
            document = preparedDocument
            text = committedText
        }

        // 独立入口(LyricsEditorSheet)要在关闭前先把歌词落盘，落盘可能失败、
        // 也可能需要二次确认，所以由它决定何时 dismiss。嵌在标签编辑器里时
        // 没有这个回调，保持原来的"改完就关"。
        if let onCommit {
            onCommit(committedText)
        } else {
            dismiss()
        }
    }

    @ViewBuilder
    private var unstampedWarningActions: some View {
        Button(String(localized: "lyrics_editor_keep_editing"), role: .cancel) {}
        Button(String(localized: "lyrics_editor_save_anyway"), role: .destructive) { commit() }
    }

    private var unstampedWarningMessage: some View {
        return Text(
            String(
                format: String(localized: "lyrics_editor_unstamped_warning_message"),
                unstampedEligibleCount
            )
        )
    }

    // MARK: - 工具

    private func timeLabel(_ time: TimeInterval) -> String {
        let centiseconds = max(0, (time * 100).rounded()).finiteInt()
        return String(
            format: "%02d:%02d.%02d",
            centiseconds / 6_000,
            (centiseconds % 6_000) / 100,
            centiseconds % 100
        )
    }

    private func visibleSyllableText(_ text: String) -> String {
        let visible = text
            .replacingOccurrences(of: " ", with: "␠")
            .replacingOccurrences(of: "\n", with: "↵")
        return visible.isEmpty ? "…" : visible
    }
}

private struct LyricsWordTimingFlowLayout: Layout {
    let horizontalSpacing: CGFloat
    let verticalSpacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        guard !subviews.isEmpty else { return .zero }

        let idealWidth = subviews.reduce(CGFloat.zero) { width, subview in
            width + subview.sizeThatFits(.unspecified).width
        } + horizontalSpacing * CGFloat(max(0, subviews.count - 1))
        let availableWidth = max(0, proposal.width ?? idealWidth)
        let dimensions = dimensions(in: availableWidth, subviews: subviews)
        return CGSize(width: availableWidth, height: dimensions.height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + verticalSpacing
                rowHeight = 0
            }
            subview.place(
                at: CGPoint(x: x, y: y),
                anchor: .topLeading,
                proposal: ProposedViewSize(size)
            )
            x += size.width + horizontalSpacing
            rowHeight = max(rowHeight, size.height)
        }
    }

    private func dimensions(in availableWidth: CGFloat, subviews: Subviews) -> CGSize {
        var x: CGFloat = 0
        var height: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widestRow: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > availableWidth {
                widestRow = max(widestRow, x - horizontalSpacing)
                height += rowHeight + verticalSpacing
                x = 0
                rowHeight = 0
            }
            x += size.width + horizontalSpacing
            rowHeight = max(rowHeight, size.height)
        }

        widestRow = max(widestRow, max(0, x - horizontalSpacing))
        height += rowHeight
        return CGSize(width: widestRow, height: height)
    }
}
