import SwiftUI
import PrimuseKit

/// 结构化歌词编辑器。逐行编辑 + 边听边打轴 + 整体偏移,替代原来在标签编辑器里
/// 那个塞在 Form 中的固定高度 TextEditor。
///
/// 真相仍然是 `text` 这个字符串 ── 保存 / 校验 / 写回音乐源的整条链路都在
/// `TagEditorView` 里以文本为单位工作,这里只是它的一个结构化视图层:进入时
/// 解析,完成时序列化写回。**没有实际编辑就不回写**,否则光是打开再关闭就会
/// 把 `[00:12.30]` 规范化成 `[00:12.300]`,让标签编辑器误以为有改动。
struct LyricsEditorView: View {
    let song: Song
    @Binding var text: String

    @Environment(AudioPlayerService.self) private var player
    @Environment(\.dismiss) private var dismiss

    @State private var document: LyricsEditorDocument
    @State private var originalDocument: LyricsEditorDocument
    @State private var mode: Mode = .structured
    @State private var sourceText: String
    @State private var playbackTime: TimeInterval = 0
    @State private var isTapSyncing = false
    @State private var showShiftPanel = false
    @State private var showUnstampedWarning = false
    /// 整体偏移用"基线 + 待定量"模型:每次都从基线重算,而不是在当前值上累加。
    /// 累加式在负向撞到 0 被 clamp 后就回不去了。
    @State private var shiftBaseline: LyricsEditorDocument?
    @State private var pendingShift: TimeInterval = 0

    @FocusState private var focusedLine: UUID?

    enum Mode { case structured, source }

    init(song: Song, text: Binding<String>) {
        self.song = song
        self._text = text
        let parsed = LyricsEditorDocument(parsing: text.wrappedValue)
        _document = State(initialValue: parsed)
        _originalDocument = State(initialValue: parsed)
        _sourceText = State(initialValue: text.wrappedValue)
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
            editorStack
                .navigationTitle(String(localized: "lyrics_editor_title"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(String(localized: "cancel")) { dismiss() }
                    }
                    ToolbarItem(placement: .principal) { modePicker }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(String(localized: "done")) { requestCommit() }
                    }
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button(String(localized: "done")) { focusedLine = nil }
                    }
                }
        }
        .presentationDragIndicator(.visible)
        .confirmationDialog(
            String(localized: "lyrics_editor_unstamped_warning_title"),
            isPresented: $showUnstampedWarning,
            titleVisibility: .visible
        ) { unstampedWarningActions } message: { unstampedWarningMessage }
        .sheet(isPresented: $showShiftPanel) { shiftPanel }
    }
    #endif

    #if os(macOS)
    private var macContainer: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(String(localized: "lyrics_editor_title"))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(PMColor.text)
                Spacer()
                modePicker
                    .frame(width: 190)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Rectangle().fill(PMColor.divider).frame(height: 0.5)

            editorStack

            Rectangle().fill(PMColor.divider).frame(height: 0.5)

            HStack(spacing: 10) {
                stampProgressLabel
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Text(String(localized: "cancel"))
                        .font(PMFont.bodyM)
                        .foregroundStyle(PMColor.text)
                        .frame(height: 26)
                        .padding(.horizontal, 14)
                }
                .buttonStyle(.plain)

                Button {
                    requestCommit()
                } label: {
                    Text(String(localized: "done"))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(height: 26)
                        .padding(.horizontal, 16)
                        .background(PMColor.brand, in: .rect(cornerRadius: 5))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 620, height: 680)
        .background(PMColor.bg)
        .foregroundStyle(PMColor.text)
        .confirmationDialog(
            String(localized: "lyrics_editor_unstamped_warning_title"),
            isPresented: $showUnstampedWarning,
            titleVisibility: .visible
        ) { unstampedWarningActions } message: { unstampedWarningMessage }
        .sheet(isPresented: $showShiftPanel) { shiftPanel }
    }
    #endif

    private var editorStack: some View {
        VStack(spacing: 0) {
            transportBar
            Divider()

            switch mode {
            case .structured:
                lineList
                bottomBar
            case .source:
                sourceEditor
            }
        }
    }

    private var modePicker: some View {
        Picker("", selection: modeBinding) {
            Text(String(localized: "lyrics_editor_mode_structured")).tag(Mode.structured)
            Text(String(localized: "lyrics_editor_mode_source")).tag(Mode.source)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    /// 切模式时把当前模式的内容同步过去,否则在源码里改完切回来会看到旧数据。
    private var modeBinding: Binding<Mode> {
        Binding(
            get: { mode },
            set: { newMode in
                guard newMode != mode else { return }
                switch newMode {
                case .source:
                    sourceText = document.serialized()
                case .structured:
                    document = LyricsEditorDocument(parsing: sourceText)
                }
                mode = newMode
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
                if abs(now - playbackTime) > 0.02 { playbackTime = now }
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    // MARK: - 行列表

    private var activeIndex: Int? {
        isLinkedToPlayback ? document.activeLineIndex(at: playbackTime) : nil
    }

    private var lineList: some View {
        ScrollViewReader { proxy in
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
            .onChange(of: document.nextUnstampedIndex) { _, next in
                // 只在打轴模式自动滚动。普通编辑时把用户从正在敲的行拽走最招人烦。
                guard isTapSyncing, let next, document.lines.indices.contains(next) else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(document.lines[next].id, anchor: .center)
                }
            }
        }
    }

    private func lineRow(line: EditableLyricLine, index: Int) -> some View {
        let isActive = activeIndex == index
        let isNextToStamp = isTapSyncing && document.nextUnstampedIndex == index

        return HStack(alignment: .top, spacing: 10) {
            timestampChip(line: line, index: index)

            TextField(
                String(localized: "lyrics_editor_line_placeholder"),
                text: textBinding(for: index),
                axis: .vertical
            )
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .focused($focusedLine, equals: line.id)

            if line.isWordLevel {
                Image(systemName: "waveform")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .help(String(localized: "lyrics_editor_word_level_hint"))
            }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(rowBackground(isActive: isActive, isNextToStamp: isNextToStamp))
        }
        .contextMenu {
            Button(String(localized: "lyrics_editor_stamp_now")) { stampWithCurrentTime(index) }
                .disabled(!isLinkedToPlayback)
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
                document.removeLines(at: IndexSet(integer: index))
            }
        }
    }

    private func rowBackground(isActive: Bool, isNextToStamp: Bool) -> Color {
        if isNextToStamp { return Color.accentColor.opacity(0.20) }
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
            set: { document.updateText($0, at: index) }
        )
    }

    // MARK: - 底部工具条

    private var bottomBar: some View {
        VStack(spacing: 0) {
            Divider()

            if isTapSyncing {
                tapSyncBar
            } else {
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

                    Spacer()

                    Button {
                        startTapSync()
                    } label: {
                        Label(String(localized: "lyrics_editor_tap_sync"), systemImage: "stopwatch")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .disabled(!isLinkedToPlayback || document.lines.isEmpty)
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
    }

    private var tapSyncBar: some View {
        VStack(spacing: 8) {
            if let next = document.nextUnstampedIndex {
                Text(document.lines[next].text.isEmpty
                     ? String(localized: "lyrics_editor_line_placeholder")
                     : document.lines[next].text)
                    .font(.system(size: 15, weight: .medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)

                Button {
                    stampNextLine()
                } label: {
                    Text(String(localized: "lyrics_editor_mark_line"))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(Color.accentColor, in: .rect(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            } else {
                Label(String(localized: "lyrics_editor_all_stamped"), systemImage: "checkmark.circle.fill")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.green)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
            }

            Button(String(localized: "lyrics_editor_exit_tap_sync")) {
                isTapSyncing = false
            }
            .font(.caption)
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var stampProgressLabel: some View {
        Group {
            if document.unstampedCount > 0, document.stampedCount > 0 {
                Label(
                    String(
                        format: String(localized: "lyrics_editor_partial_progress"),
                        document.stampedCount,
                        document.lines.count
                    ),
                    systemImage: "exclamationmark.triangle"
                )
                .foregroundStyle(.orange)
            } else if document.stampedCount > 0 {
                Label(String(localized: "lyrics_editor_all_stamped"), systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            } else {
                Label(String(localized: "lyrics_editor_plain_text"), systemImage: "text.alignleft")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
    }

    // MARK: - 源码模式

    private var sourceEditor: some View {
        TextEditor(text: $sourceText)
            .font(.system(size: 12, design: .monospaced))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                    showShiftPanel = false
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

    // MARK: - 打轴动作

    private func stampWithCurrentTime(_ index: Int) {
        guard isLinkedToPlayback else { return }
        document.stamp(at: index, time: player.interpolatedTime())
    }

    private func startTapSync() {
        isTapSyncing = true
        focusedLine = nil
        if !player.isPlaying { player.resume() }
    }

    private func stampNextLine() {
        guard let next = document.nextUnstampedIndex else { return }
        document.stamp(at: next, time: player.interpolatedTime())
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

    // MARK: - 提交

    private var hasEdits: Bool {
        switch mode {
        case .structured: return document != originalDocument
        case .source: return sourceText != originalDocument.serialized()
        }
    }

    /// 部分打轴的文档存下去会掉行 ── `LyricsContentParser.parseText` 一旦发现
    /// 存在带时间戳的行,就只返回那些行,未打轴的会被静默丢弃。所以这里拦一道。
    private var willDropUnstampedLines: Bool {
        let target = mode == .source ? LyricsEditorDocument(parsing: sourceText) : document
        return target.stampedCount > 0 && target.unstampedCount > 0
    }

    private func requestCommit() {
        if willDropUnstampedLines {
            showUnstampedWarning = true
            return
        }
        commit()
    }

    private func commit() {
        if mode == .source {
            document = LyricsEditorDocument(parsing: sourceText)
        }
        // 没改就不回写,免得规范化后的文本让标签编辑器误判有改动。
        if hasEdits { text = document.serialized() }
        dismiss()
    }

    @ViewBuilder
    private var unstampedWarningActions: some View {
        Button(String(localized: "lyrics_editor_keep_editing"), role: .cancel) {}
        Button(String(localized: "lyrics_editor_save_anyway"), role: .destructive) { commit() }
    }

    private var unstampedWarningMessage: some View {
        let target = mode == .source ? LyricsEditorDocument(parsing: sourceText) : document
        return Text(
            String(
                format: String(localized: "lyrics_editor_unstamped_warning_message"),
                target.unstampedCount
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
}
