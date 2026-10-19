import SwiftUI
import PrimuseKit
#if os(macOS)
import AppKit
import UniformTypeIdentifiers
#endif

/// 「播放时间段」在菜单里的样子:设过时间段时是一个开关(标题下面写着时间段)
/// 加一项「编辑」,一点就能开关;没设过时只有「设置播放时间段…」。最后一项是
/// 「制作铃声或导出片段」,打开同一个面板的另一页。
/// 读写都走 `SongPlaybackRangeStore`,不依赖环境,菜单放在单独的宿主里也能用。
struct SongPlaybackRangeMenuItems: View {
    let song: Song
    let onEdit: (SongPlaybackRangeEditor.Purpose) -> Void

    var body: some View {
        let store = SongPlaybackRangeStore.shared
        if SongPlaybackRangeAvailability.supports(song) {
            if let range = store.range(for: song) {
                Toggle(isOn: Binding(
                    get: { range.isEnabled },
                    set: { store.setEnabled($0, for: song) }
                )) {
                    Label {
                        Text("playback_range_title")
                        Text(verbatim: SongPlaybackRangePolicy.rangeLabel(range))
                    } icon: {
                        Image(systemName: "selection.pin.in.out")
                    }
                }
                Button { onEdit(.playbackRange) } label: {
                    Label(String(localized: "playback_range_edit"), systemImage: "slider.horizontal.3")
                }
            } else {
                Button { onEdit(.playbackRange) } label: {
                    Label(String(localized: "playback_range_set"), systemImage: "selection.pin.in.out")
                }
            }
            Button { onEdit(.clip) } label: {
                Label(SongPlaybackRangeEditor.clipMenuTitle, systemImage: SongPlaybackRangeEditor.clipSymbol)
            }
        }
    }
}

/// 设置一首歌的播放时间段,或者选一段做成铃声、导出成音频文件,两页共用一条时间轴。
///
/// 播放时间段那页:开关和时间段放在同一张卡片里,开关下面直接写着时间段与时长;拖动把手、
/// 微调或「设为当前位置」都会顺手把开关打开,关掉开关只是暂时整首播放,时间段还留着。每一步
/// 都立刻存下,正在播的就是这首歌时播放器随即按新的时间段接着播。
///
/// 铃声与导出那页:选的一段只用来导出,不存、不影响播放。打开时先用这首歌设过的时间段,
/// 没设过就用记过的高潮。两页都能「定位到高潮」(和串烧找高潮是同一套分析)。
struct SongPlaybackRangeEditor: View {
    enum Purpose: Hashable {
        case playbackRange
        case clip
    }

    @Environment(AudioPlayerService.self) private var player
    @Environment(\.dismiss) private var dismiss

    private let song: Song
    @State private var purpose: Purpose
    @State private var draft: SongPlaybackRange
    @State private var hasStoredRange: Bool
    /// 铃声与导出那页选的一段;只在这个面板里。
    @State private var clipDraft: SongPlaybackRange
    @State private var highlightTask: Task<Void, Never>?
    @State private var locatingPurpose: Purpose?
    @State private var highlightNotice: String?
    @AppStorage("primuse.clipExport.appliesFades") private var appliesClipFades = true
    @State private var exportTask: Task<Void, Never>?
    @State private var exportPhase: AudioClipExporter.Phase?
    @State private var exportError: String?
    @State private var exportedClip: ExportedClip?
    #if os(macOS)
    @State private var savedClipName: String?
    #else
    /// 铃声与导出那页要往下翻才看得到导出按钮,从那页打开时直接展开。
    @State private var detent: PresentationDetent
    #endif

    init(song: Song, purpose: Purpose = .playbackRange) {
        let whole = song.withoutAppliedPlaybackRange
        self.song = whole
        let stored = SongPlaybackRangeStore.shared.range(for: whole)
        let initial = stored ?? SongPlaybackRangePolicy.initialRange(songDuration: whole.duration)
        _purpose = State(initialValue: purpose)
        _draft = State(initialValue: initial)
        _hasStoredRange = State(initialValue: stored != nil)
        _clipDraft = State(initialValue: Self.initialClip(for: whole, stored: stored))
        #if !os(macOS)
        _detent = State(initialValue: purpose == .clip ? .large : .medium)
        #endif
    }

    static var clipMenuTitle: String {
        #if os(macOS)
        String(localized: "clip_export_menu_mac")
        #else
        String(localized: "clip_export_menu")
        #endif
    }

    static let clipSymbol = "bell.and.waves.left.and.right"

    private static var clipTabTitle: String {
        #if os(macOS)
        String(localized: "clip_export_tab_mac")
        #else
        String(localized: "clip_export_tab")
        #endif
    }

    /// 导出那页开始时选的一段:设过的时间段,其次记过的高潮(做铃声从副歌开始、不超过 30 秒),
    /// 都没有就从头取 30 秒。
    private static func initialClip(for song: Song, stored: SongPlaybackRange?) -> SongPlaybackRange {
        let duration = song.duration.isFinite ? max(0, song.duration) : 0
        if let stored, stored.length >= SongPlaybackRangePolicy.minimumLength {
            return SongPlaybackRange(start: stored.start, end: min(stored.end, duration), isEnabled: true)
        }
        if let highlight = MedleyHighlightStore.shared.highlight(for: song),
           let range = AudioClipExportPolicy.range(
               highlightStart: highlight.start,
               highlightEnd: highlight.end,
               songDuration: duration,
               maximumLength: AudioClipExportPolicy.ringtoneMaximumLength
           ) {
            return range
        }
        return SongPlaybackRange(
            start: 0,
            end: min(duration, AudioClipExportPolicy.ringtoneMaximumLength),
            isEnabled: true
        )
    }

    private var isCurrentSong: Bool { player.currentSong?.id == song.id }

    /// 曲库里记的时长;还没有时用播放器这次量到的。
    private var songDuration: TimeInterval {
        if song.duration > 0 { return song.duration }
        if isCurrentSong, let current = player.currentSong {
            let whole = current.withoutAppliedPlaybackRange.duration
            return whole > 0 ? whole : player.duration
        }
        return 0
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    purposePicker
                    if songDuration > 0 {
                        switch purpose {
                        case .playbackRange:
                            playbackRangePage
                        case .clip:
                            clipPage
                        }
                    } else {
                        Text("playback_range_unknown_duration")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle(Text(verbatim: purpose == .clip ? Self.clipTabTitle : String(localized: "playback_range_title")))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "done")) { dismiss() }
                }
            }
        }
        .onAppear {
            // 曲库里还没有时长、打开时才从播放器知道的那种,结束点补成整首。
            if draft.end <= 0, songDuration > 0 {
                draft = SongPlaybackRangePolicy.initialRange(songDuration: songDuration)
            }
            if clipDraft.end <= 0, songDuration > 0 {
                clipDraft = SongPlaybackRange(
                    start: 0,
                    end: min(songDuration, AudioClipExportPolicy.ringtoneMaximumLength),
                    isEnabled: true
                )
            }
        }
        .onDisappear {
            highlightTask?.cancel()
            exportTask?.cancel()
        }
        #if DEBUG
        .task { await runDebugClipActions() }
        #endif
        #if os(iOS)
        .sheet(item: $exportedClip) { clip in
            ShareSheet(items: [clip.url])
                .presentationDetents([.medium, .large])
        }
        #endif
        #if os(macOS)
        .frame(minWidth: 460, idealWidth: 500, minHeight: 420, idealHeight: 520)
        #else
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationDragIndicator(.visible)
        #endif
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(song.title)
                .font(.headline)
                .lineLimit(2)
            if let artist = song.artistName, !artist.isEmpty {
                Text(artist)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var purposePicker: some View {
        Picker(selection: Binding(
            get: { purpose },
            set: { newValue in
                highlightNotice = nil
                exportError = nil
                purpose = newValue
                #if !os(macOS)
                if newValue == .clip { detent = .large }
                #endif
            }
        )) {
            Text("playback_range_title").tag(Purpose.playbackRange)
            Text(verbatim: Self.clipTabTitle).tag(Purpose.clip)
        } label: {
            EmptyView()
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    // MARK: - Playback range page

    @ViewBuilder
    private var playbackRangePage: some View {
        rangeCard
        if isCurrentSong { previewButtons(for: draft) }
        Text("playback_range_footer")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        if hasStoredRange {
            Button(role: .destructive, action: clear) {
                Label(String(localized: "playback_range_clear"), systemImage: "arrow.uturn.backward")
            }
            .buttonStyle(.borderless)
        }
    }

    private func summary(of range: SongPlaybackRange) -> String {
        String(
            format: String(localized: "playback_range_summary %@ %@"),
            SongPlaybackRangePolicy.rangeLabel(range, showsTenths: true),
            SongPlaybackRangePolicy.timeLabel(range.length, showsTenths: true)
        )
    }

    private var rangeCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle(isOn: Binding(
                get: { draft.isEnabled },
                set: { enabled in
                    draft.isEnabled = enabled
                    commit(enabling: false)
                }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("playback_range_toggle")
                        .font(.body.weight(.semibold))
                    Text(verbatim: summary(of: draft))
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)

            SongPlaybackRangeTrack(
                range: $draft,
                songDuration: songDuration,
                playhead: isCurrentSong ? player.currentTime : nil,
                onCommit: { commit() }
            )

            edgeRow(.start, of: draft)
            edgeRow(.end, of: draft)
            highlightRow(for: .playbackRange)
        }
        .padding(16)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: - Clip page

    @ViewBuilder
    private var clipPage: some View {
        clipCard
        if isCurrentSong { previewButtons(for: clipDraft) }
        exportSection
    }

    private var clipCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("clip_export_selection")
                    .font(.body.weight(.semibold))
                Text(verbatim: summary(of: clipDraft))
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            SongPlaybackRangeTrack(
                range: $clipDraft,
                songDuration: songDuration,
                playhead: isCurrentSong ? player.currentTime : nil,
                onCommit: {}
            )

            edgeRow(.start, of: clipDraft)
            edgeRow(.end, of: clipDraft)
            highlightRow(for: .clip)
        }
        .padding(16)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder
    private var exportSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: $appliesClipFades) {
                Text("clip_export_fades")
            }
            .toggleStyle(.switch)

            #if os(iOS)
            if AudioClipExportPolicy.ringtoneIsShortened(length: clipDraft.length) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("clip_export_ringtone_too_long")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button(String(localized: "clip_export_trim_to_ringtone")) { trimClipToRingtone() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
            #endif

            if let exportPhase {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(verbatim: Self.phaseText(exportPhase))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Button(String(localized: "cancel"), role: .cancel) { cancelExport() }
                        .buttonStyle(.borderless)
                }
            } else {
                exportButtons
            }

            if let exportError {
                Text(verbatim: exportError)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            #if os(macOS)
            if let savedClipName {
                Label {
                    Text(verbatim: String(format: String(localized: "clip_export_saved %@"), savedClipName))
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            #endif

            Text(verbatim: Self.exportFooter)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var exportButtons: some View {
        #if os(iOS)
        VStack(alignment: .leading, spacing: 10) {
            Button { startExport(.ringtone) } label: {
                Label(String(localized: "clip_export_ringtone"), systemImage: "bell.badge")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            Button { startExport(.clip) } label: {
                Label(String(localized: "clip_export_audio"), systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
        #else
        Button { startExport(.clip) } label: {
            Label(String(localized: "clip_export_audio_mac"), systemImage: "square.and.arrow.down")
        }
        .buttonStyle(.borderedProminent)
        #endif
    }

    /// 铃声怎么设上去:iOS 26 起分享菜单里有「用作铃声」;更早的系统要借库乐队。
    private static var exportFooter: String {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            return String(localized: "clip_export_ringtone_hint")
        }
        return String(localized: "clip_export_ringtone_hint_legacy")
        #else
        return String(localized: "clip_export_footer_mac")
        #endif
    }

    private static func phaseText(_ phase: AudioClipExporter.Phase) -> String {
        switch phase {
        case .fetchingAudio: String(localized: "clip_export_phase_fetching")
        case .writing: String(localized: "clip_export_phase_writing")
        }
    }

    // MARK: - Shared rows

    private func edgeRow(_ edge: SongPlaybackRangePolicy.Edge, of range: SongPlaybackRange) -> some View {
        let value = edge == .start ? range.start : range.end
        let title = edge == .start
            ? String(localized: "playback_range_start")
            : String(localized: "playback_range_end")
        return HStack(spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .frame(minWidth: 40, alignment: .leading)
            Button {
                move(edge, to: value - SongPlaybackRangePolicy.nudgeStep)
            } label: {
                Image(systemName: "minus")
                    .frame(width: 16, height: 16)
            }
            .buttonRepeatBehavior(.enabled)
            .accessibilityLabel(Text("playback_range_nudge_earlier"))
            Text(verbatim: SongPlaybackRangePolicy.timeLabel(value, showsTenths: true))
                .font(.body.monospacedDigit())
                .frame(minWidth: 64)
                .accessibilityLabel(Text(verbatim: title))
            Button {
                move(edge, to: value + SongPlaybackRangePolicy.nudgeStep)
            } label: {
                Image(systemName: "plus")
                    .frame(width: 16, height: 16)
            }
            .buttonRepeatBehavior(.enabled)
            .accessibilityLabel(Text("playback_range_nudge_later"))
            Spacer(minLength: 4)
            if isCurrentSong {
                Button {
                    // 十分之一秒够准,也不会把 2:03.4567 这种数显示出来。
                    move(edge, to: (player.currentTime * 10).rounded() / 10)
                } label: {
                    // 窄屏上写不下整句时只留图标,不截成「设为当…」。
                    ViewThatFits(in: .horizontal) {
                        Label(String(localized: "playback_range_set_to_current"), systemImage: "scope")
                            .labelStyle(.titleAndIcon)
                            .lineLimit(1)
                            .fixedSize()
                        Image(systemName: "scope")
                    }
                }
                .accessibilityLabel(Text("playback_range_set_to_current"))
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    /// 「定位到高潮」:找的时候换成转圈和取消,没找到在下面说一句。
    private func highlightRow(for page: Purpose) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                if locatingPurpose == page {
                    ProgressView()
                        .controlSize(.small)
                    Text("playback_range_highlight_running")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Button(String(localized: "cancel"), role: .cancel) { cancelHighlight() }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                } else {
                    Button { locateHighlight(for: page) } label: {
                        Label(String(localized: "playback_range_highlight"), systemImage: "waveform.badge.magnifyingglass")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(locatingPurpose != nil || exportPhase != nil)
                }
            }
            if let highlightNotice, locatingPurpose == nil {
                Text(verbatim: highlightNotice)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func previewButtons(for range: SongPlaybackRange) -> some View {
        HStack(spacing: 10) {
            Button {
                player.seek(to: range.start, startPlaying: true)
            } label: {
                Label(String(localized: "playback_range_preview_start"), systemImage: "play.fill")
            }
            Button {
                player.seek(to: max(range.start, range.end - 5), startPlaying: true)
            } label: {
                Label(String(localized: "playback_range_preview_end"), systemImage: "forward.end.fill")
            }
        }
        .buttonStyle(.bordered)
    }

    // MARK: - Actions

    private func move(_ edge: SongPlaybackRangePolicy.Edge, to value: TimeInterval) {
        switch purpose {
        case .playbackRange:
            draft = SongPlaybackRangePolicy.moving(edge, of: draft, to: value, songDuration: songDuration)
            commit()
        case .clip:
            clipDraft = SongPlaybackRangePolicy.moving(edge, of: clipDraft, to: value, songDuration: songDuration)
        }
    }

    /// 存下草稿。调整时间段默认就是要用它,所以顺手打开开关。
    private func commit(enabling: Bool = true) {
        if enabling { draft.isEnabled = true }
        SongPlaybackRangeStore.shared.setRange(draft, for: song)
        hasStoredRange = true
    }

    private func clear() {
        SongPlaybackRangeStore.shared.clearRange(for: song)
        draft = SongPlaybackRangePolicy.initialRange(songDuration: songDuration)
        hasStoredRange = false
    }

    private func trimClipToRingtone() {
        clipDraft.end = min(songDuration, clipDraft.start + AudioClipExportPolicy.ringtoneMaximumLength)
    }

    private func locateHighlight(for page: Purpose) {
        highlightTask?.cancel()
        highlightNotice = nil
        locatingPurpose = page
        let duration = songDuration
        var measured = song
        if measured.duration <= 0 { measured.duration = duration }
        let target = measured
        highlightTask = Task {
            defer {
                if !Task.isCancelled { locatingPurpose = nil }
            }
            let highlight: MedleyHighlight?
            do {
                highlight = try await player.locateHighlight(for: target)
            } catch is CancellationError {
                return
            } catch {
                highlightNotice = (error as? LocalizedError)?.errorDescription
                    ?? String(localized: "clip_export_error_unavailable")
                return
            }
            guard !Task.isCancelled else { return }
            guard let highlight, let range = AudioClipExportPolicy.range(
                highlightStart: highlight.start,
                highlightEnd: highlight.end,
                songDuration: duration,
                maximumLength: page == .clip ? AudioClipExportPolicy.ringtoneMaximumLength : nil
            ) else {
                highlightNotice = String(localized: "playback_range_highlight_none")
                return
            }
            switch page {
            case .playbackRange:
                draft = range
                commit()
            case .clip:
                clipDraft = range
            }
        }
    }

    private func cancelHighlight() {
        highlightTask?.cancel()
        highlightTask = nil
        locatingPurpose = nil
    }

    private func startExport(_ exportPurpose: AudioClipExportPolicy.Purpose) {
        exportTask?.cancel()
        exportError = nil
        #if os(macOS)
        savedClipName = nil
        #endif
        exportPhase = .fetchingAudio
        let clip = clipDraft
        var measured = song
        if measured.duration <= 0 { measured.duration = songDuration }
        let target = measured
        let fades = appliesClipFades
        exportTask = Task {
            defer {
                if !Task.isCancelled { exportPhase = nil }
            }
            do {
                let url = try await AudioClipExporter.export(
                    song: target,
                    start: clip.start,
                    end: clip.end,
                    purpose: exportPurpose,
                    appliesFades: fades,
                    sourceManager: AppServices.shared.sourceManager,
                    onPhase: { phase in exportPhase = phase }
                )
                guard !Task.isCancelled else { return }
                deliver(url)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                exportError = (error as? LocalizedError)?.errorDescription
                    ?? String(localized: "clip_export_error_unreadable")
            }
        }
    }

    private func cancelExport() {
        exportTask?.cancel()
        exportTask = nil
        exportPhase = nil
    }

    #if os(macOS)
    private func deliver(_ url: URL) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = url.lastPathComponent
        panel.allowedContentTypes = [.mpeg4Audio]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.copyItem(at: url, to: destination)
            savedClipName = destination.lastPathComponent
        } catch {
            exportError = error.localizedDescription
        }
    }
    #else
    private func deliver(_ url: URL) {
        exportedClip = ExportedClip(url: url)
    }
    #endif
}

#if DEBUG
extension SongPlaybackRangeEditor {
    /// 取证用:`PRIMUSE_DEBUG_PRESENT=clip` 弹出这一页后,`PRIMUSE_DEBUG_CLIP_ACTION=highlight,ringtone`
    /// 依次点「定位到高潮」「制作铃声」(`clip` 是「导出这段音频」),结果写日志。
    fileprivate func runDebugClipActions() async {
        guard let raw = ProcessInfo.processInfo.environment["PRIMUSE_DEBUG_CLIP_ACTION"], !raw.isEmpty else { return }
        try? await Task.sleep(for: .seconds(1))
        for step in raw.split(separator: ",").map(String.init) {
            switch step {
            case "highlight":
                locateHighlight(for: purpose)
                await highlightTask?.value
                plog("🧪 Debug clip: highlight → \(clipDraft.start)–\(clipDraft.end) notice=\(highlightNotice ?? "-")")
            case "ringtone", "clip":
                startExport(step == "ringtone" ? .ringtone : .clip)
                await exportTask?.value
                plog("🧪 Debug clip: export \(step) → \(exportedClip?.url.lastPathComponent ?? "nil") error=\(exportError ?? "-")")
            default:
                break
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }
}
#endif

/// 刚导出的一段,交给分享面板。
private struct ExportedClip: Identifiable {
    let url: URL
    var id: URL { url }
}

/// 整首歌的时间轴,两个把手框出播放时间段;正在播这首时画出播放头。
/// 拖动按整秒吸附,松手才存;读屏可以用上下滑逐秒调整。
struct SongPlaybackRangeTrack: View {
    @Binding var range: SongPlaybackRange
    let songDuration: TimeInterval
    let playhead: TimeInterval?
    let onCommit: () -> Void

    private let handleSize: CGFloat = 22
    private let hitSize: CGFloat = 44

    var body: some View {
        GeometryReader { geometry in
            let usable = max(1, geometry.size.width - handleSize)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.14))
                    .frame(width: usable, height: 6)
                    .offset(x: handleSize / 2)
                Capsule()
                    .fill(range.isEnabled ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.secondary.opacity(0.6)))
                    .frame(width: max(0, position(range.end, usable) - position(range.start, usable)), height: 6)
                    .offset(x: position(range.start, usable))
                if let playhead, playhead.isFinite {
                    Capsule()
                        .fill(Color.primary.opacity(0.75))
                        .frame(width: 2, height: 18)
                        .offset(x: position(min(max(0, playhead), songDuration), usable) - 1)
                        .accessibilityHidden(true)
                }
                handle(.start, usable: usable)
                handle(.end, usable: usable)
            }
            .frame(height: hitSize)
            .coordinateSpace(name: Self.coordinateSpace)
        }
        .frame(height: hitSize)
    }

    private static let coordinateSpace = "playbackRangeTrack"

    private func position(_ time: TimeInterval, _ usable: CGFloat) -> CGFloat {
        guard songDuration > 0 else { return handleSize / 2 }
        return handleSize / 2 + CGFloat(time / songDuration) * usable
    }

    private func handle(_ edge: SongPlaybackRangePolicy.Edge, usable: CGFloat) -> some View {
        let value = edge == .start ? range.start : range.end
        let title = edge == .start
            ? String(localized: "playback_range_start")
            : String(localized: "playback_range_end")
        return Circle()
            .fill(Color.white)
            .overlay(Circle().strokeBorder(range.isEnabled ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.secondary), lineWidth: 2))
            .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
            .frame(width: handleSize, height: handleSize)
            .frame(width: hitSize, height: hitSize)
            .contentShape(Rectangle())
            .offset(x: position(value, usable) - hitSize / 2)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.coordinateSpace))
                    .onChanged { drag in
                        let fraction = Double((drag.location.x - handleSize / 2) / usable)
                        let raw = fraction * songDuration
                        let step = SongPlaybackRangePolicy.dragStep
                        range = SongPlaybackRangePolicy.moving(
                            edge,
                            of: range,
                            to: (raw / step).rounded() * step,
                            songDuration: songDuration
                        )
                    }
                    .onEnded { _ in onCommit() }
            )
            .accessibilityElement()
            .accessibilityLabel(Text(verbatim: title))
            .accessibilityValue(Text(verbatim: SongPlaybackRangePolicy.timeLabel(value, showsTenths: true)))
            .accessibilityAdjustableAction { direction in
                let step = SongPlaybackRangePolicy.nudgeStep
                switch direction {
                case .increment:
                    range = SongPlaybackRangePolicy.moving(edge, of: range, to: value + step, songDuration: songDuration)
                case .decrement:
                    range = SongPlaybackRangePolicy.moving(edge, of: range, to: value - step, songDuration: songDuration)
                @unknown default:
                    return
                }
                onCommit()
            }
    }
}

/// 播放页进度条上的一道刻度:这首歌开着播放时间段时,标出时间段从哪里开始。
/// 进度条仍是整首歌的时间,开头那一截不会播到。画法与有声书书签刻度一致。
struct SongPlaybackRangeStartTick: View {
    let color: Color
    @Environment(AudioPlayerService.self) private var player

    var body: some View {
        if let applied = player.currentSong?.appliedPlaybackRange,
           applied.start > 0, player.duration > 0 {
            let fraction = min(1, applied.start / player.duration)
            GeometryReader { proxy in
                Capsule()
                    .fill(color)
                    .frame(width: 2, height: 9)
                    .position(x: proxy.size.width * fraction, y: proxy.size.height / 2 - 5)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

