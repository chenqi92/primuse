import PrimuseKit
import SwiftUI

/// Full-screen karaoke: large swept lyrics, vocal and key controls, and the
/// optional microphone with live pitch, scoring and recording. The karaoke
/// session lives exactly as long as this view.
struct KaraokeStageView: View {
    @Environment(AudioPlayerService.self) private var player
    @Environment(\.dismiss) private var dismiss
    @State private var session: KaraokeSession?

    var body: some View {
        Group {
            if let session {
                KaraokeStageContent(session: session, onClose: { dismiss() })
            } else {
                KaraokeStageBackdrop(isPlaying: false)
            }
        }
        .onAppear {
            guard session == nil else { return }
            let created = KaraokeSession(player: player)
            session = created
            created.start()
        }
        .onDisappear {
            session?.stop()
        }
        #if os(macOS)
        .frame(minWidth: 760, idealWidth: 900, minHeight: 620, idealHeight: 720)
        #endif
        .preferredColorScheme(.dark)
    }
}

/// 与播放页沉浸歌词同一套视觉：封面取色的氛围底、深色玻璃圆钮、白色歌词扫光。
/// 手机横屏时歌词在左、控制区在右，同一棵树只换排布。
private struct KaraokeStageContent: View {
    @Bindable var session: KaraokeSession
    let onClose: () -> Void

    @Environment(\.pmHeightClass) private var heightClass

    private var player: AudioPlayerService { session.player }

    var body: some View {
        let isSideBySide = heightClass.isCompact
        let layout = isSideBySide
            ? AnyLayout(HStackLayout(alignment: .center, spacing: 20))
            : AnyLayout(VStackLayout(spacing: 0))

        VStack(spacing: 0) {
            KaraokeStageHeader(session: session, onClose: onClose)
            layout {
                // 歌词区只拿剩下的高度：没有 minHeight 时它的最小高度就是歌词本身的高度，
                // 一句歌词折成两三行就把整棵树撑高、把底下的控制区往下顶——这就是「底部弹动」。
                // 现在超出的部分在区内居中并裁掉，控制区纹丝不动。
                stage
                    .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                    .clipped()
                KaraokeControlDeck(session: session)
                    .frame(maxWidth: isSideBySide ? 380 : 560)
            }
        }
        .padding(.horizontal, isSideBySide ? 12 : 20)
        .padding(.bottom, isSideBySide ? 8 : 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            KaraokeStageBackdrop(isPlaying: player.isPlaying)
        }
        .animation(.easeInOut(duration: 0.25), value: session.microphoneState)
        .animation(.easeInOut(duration: 0.25), value: session.isVocalAssisting)
        .animation(.easeInOut(duration: 0.25), value: session.loop)
        .sheet(item: $session.completedPerformance) { performance in
            KaraokeResultView(performance: performance, session: session)
        }
    }

    @ViewBuilder
    private var stage: some View {
        if let message = blockingMessage {
            KaraokeNotice(
                systemImage: "music.mic",
                message: message,
                actionTitle: session.availability == .highFidelityOutput
                    ? String(localized: "karaoke_use_effects_output")
                    : nil,
                action: session.useEffectsOutput
            )
        } else if session.isLoadingLyrics {
            ProgressView()
                .tint(.white)
                .accessibilityLabel(Text("karaoke_loading_lyrics"))
        } else if session.windows.isEmpty {
            KaraokeNotice(systemImage: "text.quote", message: String(localized: "karaoke_no_lyrics"))
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !player.isPlaying)) { context in
                KaraokeLyricsStage(
                    session: session,
                    time: player.interpolatedTime(at: context.date),
                    isPlaying: player.isPlaying
                )
            }
            .padding(.vertical, 12)
        }
    }

    private var blockingMessage: String? {
        switch session.availability {
        case .available: nil
        case .noSong: String(localized: "karaoke_no_song")
        case .appleMusic: String(localized: "karaoke_unavailable_apple_music")
        case .casting: String(localized: "karaoke_unavailable_casting")
        case .highFidelityOutput: String(localized: "karaoke_unavailable_high_fidelity")
        }
    }
}

// MARK: - Header

/// 收起键、封面与歌名、分数、更多。四者一律按中线对齐，圆钮与播放页沉浸模式同尺寸。
private struct KaraokeStageHeader: View {
    let session: KaraokeSession
    let onClose: () -> Void

    private var player: AudioPlayerService { session.player }

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onClose) {
                ImmersiveGlassActionLabel(symbol: closeSymbol, diameter: 40)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("close"))
            .keyboardShortcut(.cancelAction)

            CachedArtworkView(
                coverRef: player.currentSong?.coverArtFileName,
                songID: player.currentSong?.id ?? "",
                size: 44,
                cornerRadius: 8,
                sourceID: player.currentSong?.sourceID,
                filePath: player.currentSong?.filePath,
                fileFormat: player.currentSong?.fileFormat,
                revisionToken: player.coverRevision
            )
            .frame(width: 44, height: 44)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(player.currentSong?.title ?? String(localized: "karaoke_title"))
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.62))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let score = session.runningScore {
                KaraokeScoreBadge(score: score)
                    .transition(.scale.combined(with: .opacity))
            }
            KaraokeStageMenu(session: session)
        }
        .padding(.top, 12)
        .padding(.bottom, 4)
        .animation(.spring(duration: 0.3), value: session.runningScore)
    }

    /// 手机上是从底部推上来的全屏页，收起用向下箭头；Mac 是表单，用叉号。
    private var closeSymbol: String {
        #if os(iOS)
        "chevron.down"
        #else
        "xmark"
        #endif
    }

    /// 歌手之后跟一条最要紧的说明：借来的歌词出处优先，其次是 AI 推断的逐字时间。
    private var subtitle: String? {
        var parts: [String] = []
        if let artist = player.currentSong?.artistName, !artist.isEmpty {
            parts.append(artist)
        }
        if let source = session.lyricsBorrowedFromTitle {
            parts.append(String(format: String(localized: "karaoke_lyrics_from_format"), source))
        } else if session.usesInferredWordTiming {
            parts.append(String(localized: "karaoke_ai_word_timing"))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

// MARK: - Lyrics

private struct KaraokeLyricsStage: View {
    let session: KaraokeSession
    let time: TimeInterval
    let isPlaying: Bool

    @Environment(\.pmHeightClass) private var heightClass

    /// 主声部与播放页歌词同样扫成白色；对唱的另一声部用暖粉色区分。
    private static let primaryColor = Color.white
    private static let secondaryColor = Color(red: 1.0, green: 0.62, blue: 0.80)

    private static let maxWidth: CGFloat = 900

    var body: some View {
        let windows = session.windows
        let activeIndex = KaraokeLineWindowPolicy.activeWindowIndex(in: windows, at: time)
        // Between rows the upcoming row takes the stage, waiting to be swept.
        let focusIndex = activeIndex ?? windows.firstIndex(where: { $0.start > time }) ?? (windows.count - 1)
        let leadIn = KaraokeLeadInPolicy.leadIn(windows: windows, at: time)

        // 行宽决定一句会折成几行；太长的句子缩一两档字号，尽量不超过两行。
        GeometryReader { proxy in
            let rowWidth = min(proxy.size.width, Self.maxWidth)
            VStack(spacing: heightClass.value(18, compact: 10)) {
                if focusIndex > 0 {
                    row(windowIndex: focusIndex - 1, role: .previous, rowWidth: rowWidth)
                }
                KaraokeLeadInDots(leadIn: leadIn)
                row(windowIndex: focusIndex, role: activeIndex == nil ? .upcoming : .current, rowWidth: rowWidth)
                if focusIndex + 1 < windows.count {
                    row(windowIndex: focusIndex + 1, role: .next, rowWidth: rowWidth)
                }
            }
            .frame(maxWidth: Self.maxWidth)
            .animation(.easeInOut(duration: 0.35), value: focusIndex)
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }

    private enum Role {
        case previous, current, upcoming, next
    }

    /// Duets put the two singers on opposite sides; solo rows stay centred.
    private struct Side {
        var text: TextAlignment
        var horizontal: HorizontalAlignment
        var frame: Alignment
    }

    private static func side(isDuet: Bool, voice: LyricVoice) -> Side {
        guard isDuet else { return Side(text: .center, horizontal: .center, frame: .center) }
        return voice == .secondary
            ? Side(text: .trailing, horizontal: .trailing, frame: .trailing)
            : Side(text: .leading, horizontal: .leading, frame: .leading)
    }

    @ViewBuilder
    private func row(windowIndex: Int, role: Role, rowWidth: CGFloat) -> some View {
        let window = session.windows[windowIndex]
        let line = session.stageLines[window.lineIndex]
        let isDuet = session.hasDuetParts
        let voiceColor = window.voice == .secondary ? Self.secondaryColor : Self.primaryColor
        let isMine = !isDuet || session.part == .all
            || (session.part == .primary) == (window.voice == .primary)
        let side = Self.side(isDuet: isDuet, voice: window.voice)
        let baseSize: CGFloat = switch role {
        case .current, .upcoming: heightClass.value(34, compact: 26)
        case .next: heightClass.value(22, compact: 18)
        case .previous: heightClass.value(18, compact: 15)
        }
        let fontSize = CGFloat(KaraokeLineFitPolicy.fontSize(
            for: line.text,
            base: Double(baseSize),
            availableWidth: Double(rowWidth)
        ))

        VStack(alignment: side.horizontal, spacing: 4) {
            if isDuet, role == .current || role == .upcoming, session.part != .all {
                Text(isMine ? LocalizedStringKey("karaoke_you") : LocalizedStringKey("karaoke_partner"))
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(voiceColor.opacity(0.25), in: Capsule())
                    .foregroundStyle(voiceColor)
            }
            switch role {
            case .current, .upcoming:
                KaraokeLineView(
                    line: line,
                    fontSize: fontSize,
                    weight: .bold,
                    activeStyle: AnyShapeStyle(voiceColor),
                    inactiveColor: .white.opacity(isMine ? 0.42 : 0.26),
                    textAlignment: side.text,
                    timeAt: { _ in time },
                    fixedTime: time,
                    isPlaybackActive: isPlaying,
                    animatesSyllableBounce: isPlaying
                )
            case .previous, .next:
                Text(line.text)
                    .font(.system(size: fontSize, weight: .semibold))
                    .foregroundStyle(.white.opacity(role == .next ? 0.5 : 0.25))
                    .multilineTextAlignment(side.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: side.frame)
        .id(window.lineID)
        .transition(.asymmetric(
            insertion: .move(edge: .bottom).combined(with: .opacity),
            removal: .move(edge: .top).combined(with: .opacity)
        ))
    }
}

private struct KaraokeLeadInDots: View {
    let leadIn: KaraokeLeadIn?

    var body: some View {
        HStack(spacing: 10) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(.white.opacity(isLit(index) ? 0.95 : 0.15))
                    .frame(width: 10, height: 10)
                    .scaleEffect(isLit(index) ? 1 : 0.7)
            }
        }
        .opacity(leadIn == nil ? 0 : 1)
        .animation(.easeOut(duration: 0.2), value: leadIn?.remainingBeats)
        .accessibilityHidden(true)
    }

    private func isLit(_ index: Int) -> Bool {
        guard let leadIn else { return false }
        return index < leadIn.remainingBeats
    }
}

// MARK: - Pitch lane

/// The last few seconds of melody: grey bars for the original vocal, dots
/// for the singer — green when on pitch (octave folded), orange when off.
private struct KaraokePitchLane: View {
    let points: [KaraokeSession.PitchPoint]

    var body: some View {
        Canvas { context, size in
            guard let latest = points.last?.time else { return }
            let notes = points.flatMap { [$0.reference, $0.sung].compactMap { $0 } }
            let low = (notes.min() ?? 48) - 3
            let high = max(low + 12, (notes.max() ?? 72) + 3)
            let span = KaraokeSession.pitchHistoryDuration
            func x(_ time: TimeInterval) -> CGFloat {
                CGFloat((time - (latest - span)) / span) * size.width
            }
            func y(_ note: Double) -> CGFloat {
                size.height * CGFloat(1 - (note - low) / (high - low))
            }

            for point in points {
                if let reference = point.reference {
                    let rect = CGRect(x: x(point.time) - 3, y: y(reference) - 3, width: 7, height: 6)
                    context.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(.white.opacity(0.28)))
                }
            }
            for point in points {
                guard let sung = point.sung else { continue }
                var shown = sung
                var onPitch = false
                if let reference = point.reference {
                    // Draw an octave-displaced singer next to the melody.
                    shown = sung - 12 * ((sung - reference) / 12).rounded()
                    onPitch = KaraokeScorer.pitchAccuracy(sung: sung, reference: reference) >= 0.8
                }
                let color: Color = point.reference == nil ? .white.opacity(0.7) : (onPitch ? .green : .orange)
                let rect = CGRect(x: x(point.time) - 3.5, y: y(shown) - 3.5, width: 7, height: 7)
                context.fill(Path(ellipseIn: rect), with: .color(color))
            }
        }
        .karaokeGlass(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityHidden(true)
    }
}

// MARK: - Controls

/// 歌词下方的整块控制区：状态提示、音准线、调音卡片、进度条、主操作圆钮。
/// 手机横屏时它是右侧一栏，放不下就在栏内滚动。
private struct KaraokeControlDeck: View {
    @Bindable var session: KaraokeSession

    @Environment(\.pmHeightClass) private var heightClass

    var body: some View {
        ScrollView(.vertical) {
            VStack(spacing: 12) {
                KaraokeStatusStrip(session: session)
                if session.microphoneState == .on {
                    KaraokePitchLane(points: session.pitchHistory)
                        .frame(height: 64)
                        // 带唱每隔几秒就进出一次；贴在音准线上不占布局，整块高度才稳得住。
                        .overlay(alignment: .topLeading) {
                            if session.isVocalAssisting {
                                KaraokeAssistBadge()
                                    .padding(6)
                                    .transition(.opacity)
                            }
                        }
                        .transition(.opacity)
                }
                KaraokeMixerCard(session: session)
                KaraokeProgressRow(session: session)
                KaraokeTransportRow(session: session)
            }
            // 少数常驻提示出现/消失会改变整块高度，过渡一下而不是瞬间跳。
            .animation(.easeInOut(duration: 0.25), value: session.isEffectivelyMono)
            .padding(.top, 4)
        }
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize)
        // 竖屏按内容高度排在歌词下方，把剩下的高度都让给歌词；横屏是独立一栏，
        // 高度由屏幕决定，内容更高时才滚动。
        .fixedSize(horizontal: false, vertical: !heightClass.isCompact)
    }
}

/// 只放一首歌里基本不变的提示（单声道、麦克风权限、录音结果……）。
/// 循环胶囊在进度条那一行、带唱胶囊在音准线上，它们来去频繁，不能牵动这里的高度。
private struct KaraokeStatusStrip: View {
    let session: KaraokeSession

    var body: some View {
        let status = statusMessage
        if let status {
            HStack(spacing: 10) {
                Label(status, systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.78))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if let url = session.lastRecordingURL, !session.isMixingRecording {
                    ShareLink(item: url) {
                        Label("karaoke_share_recording", systemImage: "square.and.arrow.up")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.white)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .karaokeGlass(Capsule())
            .frame(maxWidth: .infinity)
            .transition(.opacity)
            .animation(.easeInOut(duration: 0.25), value: status)
        }
    }

    private var statusMessage: String? {
        if session.isPlayingInstrumental { return String(localized: "karaoke_backing_track_playing") }
        if session.isEffectivelyMono { return monoMessage }
        switch session.microphoneState {
        case .denied: return String(localized: "karaoke_mic_denied")
        case .unavailable: return String(localized: "karaoke_mic_unavailable")
        case .on where !session.canMonitor: return String(localized: "karaoke_monitor_needs_wired")
        default: break
        }
        if session.isVocalAssistSuppressed { return String(localized: "karaoke_vocal_assist_paused") }
        if session.isPracticing, session.microphoneState == .on {
            return String(localized: "karaoke_practice_not_scored")
        }
        if session.isMixingRecording { return String(localized: "karaoke_mixing") }
        if session.recordingFailed { return String(localized: "karaoke_recording_failed") }
        if session.lastRecordingURL != nil { return String(localized: "karaoke_recording_saved") }
        return nil
    }

    /// 频谱法对单声道无能为力，但 AI 分离不挑声道：能走 AI 就告诉用户差哪一步。
    private var monoMessage: String {
        let modelState = session.separation.modelState
        if modelState == .unsupportedSystem || session.currentSeparationState == .unsupported {
            return String(localized: "karaoke_mono_warning")
        }
        if !session.aiSeparationEnabled { return String(localized: "karaoke_mono_enable_ai") }
        return String(localized: "karaoke_mono_ai_pending")
    }
}

/// 人声、升降调、速度、AI 分离、伴奏与对唱。一张玻璃卡片，行与行之间用细线分开。
/// 人声滑块常驻；其余都是设一次就不动的选项，默认收成一行摘要，点开才铺开，
/// 把高度让给歌词。
private struct KaraokeMixerCard: View {
    @Bindable var session: KaraokeSession

    var body: some View {
        VStack(spacing: 0) {
            vocalRow
                .padding(.vertical, 10)
                .disabled(session.availability != .available || session.isPlayingInstrumental)

            divider
            summaryRow
                .padding(.vertical, 8)

            if session.isTuningExpanded {
                tuningRows
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 2)
        .foregroundStyle(.white)
        .karaokeGlass(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .animation(.easeInOut(duration: 0.25), value: session.isTuningExpanded)
    }

    /// 一行讲清现在的设定：AI 状态总在，其余只列改过的。点一下展开或收起。
    private var summaryRow: some View {
        Button {
            session.isTuningExpanded.toggle()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "slider.horizontal.3")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.7))
                    .accessibilityHidden(true)
                Text("karaoke_tuning")
                    .font(.subheadline.weight(.semibold))
                    .fixedSize()
                Text(summary)
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.62))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.down")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.55))
                    .rotationEffect(.degrees(session.isTuningExpanded ? 180 : 0))
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("karaoke_tuning"))
        .accessibilityValue(Text(summary))
        .accessibilityHint(Text("karaoke_tuning_hint"))
    }

    private var summary: String {
        var parts: [String] = []
        if let ai = aiSummary { parts.append(ai) }
        if session.keyShift != 0 {
            parts.append("\(String(localized: "karaoke_key")) \(keyLabel)")
        }
        if session.practiceRate < 1 {
            parts.append("\(String(localized: "karaoke_speed")) \(speedLabel)")
        }
        if session.isPlayingInstrumental {
            parts.append(String(localized: "karaoke_backing_track"))
        }
        if session.microphoneState == .on, session.isMonitoring {
            parts.append(String(localized: "karaoke_monitor"))
        }
        if session.hasDuetParts, session.part != .all {
            let part = session.part == .primary
                ? String(localized: "karaoke_part_primary")
                : String(localized: "karaoke_part_secondary")
            parts.append("\(String(localized: "karaoke_part")) \(part)")
        }
        return parts.joined(separator: " · ")
    }

    /// 收起时 AI 分离的进度、失败也要看得见，不然用户不知道该不该点开。
    private var aiSummary: String? {
        let modelState = session.separation.modelState
        guard modelState != .unsupportedSystem else { return nil }
        let state: String
        if !session.aiSeparationEnabled {
            state = String(localized: "karaoke_ai_off")
        } else {
            switch modelState {
            case .unsupportedSystem:
                return nil
            case .notDownloaded:
                state = String(localized: "karaoke_ai_preparing")
            case .downloading(let fraction):
                state = "\(String(localized: "karaoke_ai_downloading")) \(Self.percent(fraction))"
            case .failed:
                state = String(localized: "karaoke_ai_model_failed")
            case .ready:
                switch session.currentSeparationState {
                case .separating(let fraction):
                    let isCooling = session.songID.map { session.separation.coolingSongIDs.contains($0) } ?? false
                    state = isCooling
                        ? String(localized: "karaoke_ai_cooling")
                        : "\(String(localized: "karaoke_ai_separating")) \(Self.percent(fraction))"
                case .ready where session.isStemLocked:
                    state = String(localized: "karaoke_ai_active")
                case .ready:
                    state = String(localized: "karaoke_ai_aligning")
                case .unsupported:
                    state = String(localized: "karaoke_ai_unsupported_short")
                case .failed:
                    state = String(localized: "karaoke_ai_failed")
                case .idle, nil:
                    state = String(localized: "karaoke_ai_preparing")
                }
            }
        }
        return String(format: String(localized: "karaoke_ai_summary_format"), state)
    }

    private static func percent(_ fraction: Double) -> String {
        fraction.formatted(.percent.precision(.fractionLength(0)))
    }

    @ViewBuilder
    private var tuningRows: some View {
        VStack(spacing: 0) {
            divider
            HStack(spacing: 10) {
                KaraokeStepper(
                    titleKey: "karaoke_key",
                    value: keyLabel,
                    downLabel: "karaoke_key_down",
                    upLabel: "karaoke_key_up",
                    canStepDown: session.keyShift > KaraokeKeyShiftPolicy.range.lowerBound,
                    canStepUp: session.keyShift < KaraokeKeyShiftPolicy.range.upperBound,
                    stepDown: { session.keyShift -= 1 },
                    stepUp: { session.keyShift += 1 }
                )
                KaraokeStepper(
                    titleKey: "karaoke_speed",
                    value: speedLabel,
                    downLabel: "karaoke_speed_down",
                    upLabel: "karaoke_speed_up",
                    canStepDown: session.practiceRate > KaraokePracticePolicy.rates[0],
                    canStepUp: session.practiceRate < 1,
                    stepDown: { session.practiceRate = KaraokePracticePolicy.stepped(session.practiceRate, up: false) },
                    stepUp: { session.practiceRate = KaraokePracticePolicy.stepped(session.practiceRate, up: true) }
                )
            }
            .padding(.vertical, 10)
            .disabled(session.availability != .available)

            if session.separation.modelState != .unsupportedSystem {
                divider
                KaraokeAISeparationRow(session: session)
                    .padding(.vertical, 10)
            }

            if hasOptionRow {
                divider
                optionRow
                    .padding(.vertical, 10)
            }

            if session.hasDuetParts {
                divider
                Picker(selection: $session.part) {
                    Text("karaoke_part_all").tag(KaraokePart.all)
                    Text("karaoke_part_primary").tag(KaraokePart.primary)
                    Text("karaoke_part_secondary").tag(KaraokePart.secondary)
                } label: {
                    Text("karaoke_part")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.vertical, 10)
            }
        }
        .transition(.opacity)
    }

    private var divider: some View {
        Rectangle()
            .fill(.white.opacity(0.1))
            .frame(height: 0.5)
    }

    private var vocalRow: some View {
        HStack(spacing: 12) {
            Text("karaoke_vocals")
                .font(.subheadline.weight(.semibold))
                .fixedSize()
            Image(systemName: "person.slash")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.55))
                .accessibilityHidden(true)
            Slider(value: $session.vocalLevel, in: 0...1)
                .tint(.white)
                .accessibilityLabel(Text("karaoke_vocals"))
                .accessibilityValue(Text(session.vocalLevel, format: .percent.precision(.fractionLength(0))))
            Image(systemName: "person.wave.2.fill")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.55))
                .accessibilityHidden(true)
        }
    }

    private var hasOptionRow: Bool {
        session.canToggleBackingTrack || session.isSwitchingTrack || session.microphoneState == .on
    }

    /// 伴奏音轨与耳返：两颗可选中的胶囊，左对齐排开。
    private var optionRow: some View {
        HStack(spacing: 8) {
            if session.canToggleBackingTrack || session.isSwitchingTrack {
                KaraokeOptionPill(
                    titleKey: "karaoke_backing_track",
                    systemImage: session.isPlayingInstrumental ? "checkmark" : "music.quarternote.3",
                    isOn: session.isPlayingInstrumental,
                    isBusy: session.isSwitchingTrack,
                    action: session.toggleBackingTrack
                )
                .disabled(session.isSwitchingTrack)
            }
            if session.microphoneState == .on {
                KaraokeOptionPill(
                    titleKey: "karaoke_monitor",
                    systemImage: "headphones",
                    isOn: session.isMonitoring,
                    action: { session.isMonitoring.toggle() }
                )
                .disabled(!session.canMonitor)
            }
            Spacer(minLength: 0)
        }
    }

    private var speedLabel: String {
        session.practiceRate >= 1
            ? String(localized: "karaoke_speed_normal")
            : String(format: "%.1f×", session.practiceRate)
    }

    private var keyLabel: String {
        session.keyShift == 0
            ? String(localized: "karaoke_key_original")
            : String(format: "%+d", session.keyShift)
    }
}

/// 与播放页同一条进度条，可拖动。拖离循环的句子会照常退出循环。
/// 时间那一行定高，循环中的「循环 N 句 / 加一句」胶囊和点了「结算」「录音」后的提示
/// 都放在两端时间中间，来去不改高度。
private struct KaraokeProgressRow: View {
    let session: KaraokeSession

    private var player: AudioPlayerService { session.player }

    var body: some View {
        VStack(spacing: 2) {
            ProgressSlider(
                value: player.currentTime,
                total: player.duration,
                interactionID: player.currentSong?.id,
                fillTint: .white,
                onSeek: { player.seek(to: $0) }
            )
            HStack(spacing: 8) {
                Text(player.currentTime.formattedDuration)
                Spacer(minLength: 0)
                if let hint = session.transportHint {
                    KaraokeHintChip(text: hint.message)
                        .transition(.opacity)
                } else if let loop = session.loop {
                    KaraokeLoopChip(session: session, lineCount: loop.lineCount)
                        .transition(.opacity)
                }
                Spacer(minLength: 0)
                Text(player.duration.formattedDuration)
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.white.opacity(0.55))
            .frame(height: 22)
            .animation(.easeInOut(duration: 0.25), value: session.transportHint)
            .onChange(of: session.transportHint) { _, hint in
                if let hint { AccessibilityNotification.Announcement(hint.message).post() }
            }
            // 进度条自带 44 点高的拖动热区，时间贴回细条下方。
            .padding(.top, -12)
        }
    }
}

/// 麦克风、录音、播放、循环、结算五个等宽槽位。每个槽位都是「64 点高的按钮区 + 一行说明」，
/// 播放键没有说明也占着同样高的一行，所以五个圆心永远在一条线上。
private struct KaraokeTransportRow: View {
    let session: KaraokeSession

    private var player: AudioPlayerService { session.player }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            KaraokeTransportSlot(titleKey: "karaoke_microphone") {
                KaraokeGlassToggle(
                    systemImage: session.microphoneState == .on ? "mic.fill" : "mic",
                    isOn: session.microphoneState == .on,
                    isBusy: session.microphoneState == .starting,
                    action: session.toggleMicrophone
                )
                .accessibilityLabel(Text("karaoke_microphone"))
            }
            KaraokeTransportSlot(
                titleKey: session.isRecording
                    ? LocalizedStringKey("karaoke_stop_recording")
                    : LocalizedStringKey("karaoke_record")
            ) {
                // 差的是用户自己能补的一步（开麦克风、退出练习）时照样能点，点了说明差什么。
                KaraokeGlassToggle(
                    systemImage: session.isRecording ? "stop.fill" : "record.circle",
                    isOn: session.isRecording,
                    tint: .red,
                    isBusy: session.isMixingRecording,
                    isDimmed: session.recordBlocker != nil,
                    action: session.toggleRecording
                )
                .disabled(!session.isRecording && !session.canRecord && session.recordBlocker == nil)
                .accessibilityLabel(Text(session.isRecording
                    ? LocalizedStringKey("karaoke_stop_recording")
                    : LocalizedStringKey("karaoke_record")))
            }
            KaraokeTransportSlot(titleKey: nil) {
                Button {
                    player.togglePlayPause()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 24, weight: .semibold))
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 64, height: 64)
                        .background(.white, in: Circle())
                        .foregroundStyle(.black)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(player.isPlaying ? LocalizedStringKey("pause") : LocalizedStringKey("play")))
                .keyboardShortcut(.space, modifiers: [])
            }
            KaraokeTransportSlot(titleKey: "karaoke_loop") {
                KaraokeGlassToggle(
                    systemImage: "repeat",
                    isOn: session.loop != nil,
                    action: session.toggleLoop
                )
                .disabled(session.loop == nil && (session.windows.isEmpty || session.availability != .available))
                .accessibilityLabel(Text(session.loop != nil
                    ? LocalizedStringKey("karaoke_loop_stop")
                    : LocalizedStringKey("karaoke_loop")))
            }
            KaraokeTransportSlot(titleKey: "karaoke_finish") {
                // 还没有分数时不置灰禁用：点了说明要先开麦克风唱几句，免得像坏了一样没反应。
                KaraokeGlassToggle(
                    systemImage: "flag.checkered",
                    isOn: false,
                    isDimmed: session.finishBlocker != nil,
                    action: session.finishPerformance
                )
                .accessibilityLabel(Text("karaoke_finish"))
            }
        }
    }
}

private struct KaraokeTransportSlot<Control: View>: View {
    let titleKey: LocalizedStringKey?
    @ViewBuilder let control: Control

    var body: some View {
        VStack(spacing: 6) {
            control
                .frame(height: 64)
            Group {
                if let titleKey {
                    Text(titleKey)
                } else {
                    Text(verbatim: " ").hidden()
                }
            }
            .font(.caption2)
            .foregroundStyle(.white.opacity(0.7))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity)
    }
}

/// 深色玻璃圆钮，打开时换成选中态的描边与底色，和播放页沉浸模式的圆钮一致。
private struct KaraokeGlassToggle: View {
    let systemImage: String
    let isOn: Bool
    var tint: Color = .white
    var isBusy = false
    /// Looks unavailable but still takes the tap, which explains what is missing.
    var isDimmed = false
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            ZStack {
                ImmersiveGlassActionLabel(
                    symbol: isBusy ? "circle" : systemImage,
                    tint: isOn ? tint : .white,
                    diameter: 50,
                    isSelected: isOn
                )
                .opacity(isBusy ? 0 : 1)
                if isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                        .frame(width: 50, height: 50)
                        .karaokeGlass(Circle())
                }
            }
            .opacity(isEnabled && !isDimmed ? 1 : 0.4)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// 卡片里的可选中胶囊（伴奏音轨、耳返）。
private struct KaraokeOptionPill: View {
    let titleKey: LocalizedStringKey
    let systemImage: String
    let isOn: Bool
    var isBusy = false
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if isBusy {
                    ProgressView().controlSize(.mini).tint(.white)
                } else {
                    Image(systemName: systemImage)
                        .font(.footnote.weight(.semibold))
                }
                Text(titleKey)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            .foregroundStyle(isOn ? .black : .white)
            .background(isOn ? AnyShapeStyle(.white) : AnyShapeStyle(.white.opacity(0.1)), in: Capsule())
            .contentShape(Capsule())
            .opacity(isEnabled ? 1 : 0.4)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// AI separation status: download, progress, and whether it is in effect.
/// 标题下只有一行状态，重试键靠在开关旁边；下载或分离失败时把原因写在状态行里，
/// 不再只给一个光秃秃的「重试」。
private struct KaraokeAISeparationRow: View {
    @Bindable var session: KaraokeSession

    var body: some View {
        if session.separation.modelState != .unsupportedSystem {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Label("karaoke_ai_title", systemImage: "sparkles")
                        .font(.subheadline.weight(.semibold))
                        .labelStyle(.titleAndIcon)
                    if session.aiSeparationEnabled {
                        status
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.75))
                    } else if session.separation.modelState == .notDownloaded
                                || session.separation.modelState == .failed {
                        // 打开开关就会开始下载，先把体积说清楚。
                        Text(String(
                            format: String(localized: "karaoke_ai_download_on_enable_format"),
                            ByteCountFormatter.string(fromByteCount: KaraokeVocalModel.approximateDownloadBytes, countStyle: .file)
                        ))
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.6))
                    }
                }
                Spacer(minLength: 8)
                if let retry = retryAction {
                    Button("karaoke_ai_retry", action: retry)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                Toggle("karaoke_ai_title", isOn: $session.aiSeparationEnabled)
                    .labelsHidden()
            }
            .foregroundStyle(.white)
        }
    }

    /// 模型没下来重试下载；这首歌没分离成重试分离。
    private var retryAction: (() -> Void)? {
        guard session.aiSeparationEnabled else { return nil }
        switch session.separation.modelState {
        case .failed:
            return { session.separation.downloadModel() }
        case .ready where session.currentSeparationState == .failed:
            return session.retrySeparation
        default:
            return nil
        }
    }

    @ViewBuilder
    private var status: some View {
        switch session.separation.modelState {
        case .unsupportedSystem:
            EmptyView()
        case .notDownloaded:
            // 开关一打开就在下载了；这里只会闪一下。
            Text("karaoke_ai_preparing")
        case .downloading(let fraction):
            progress(String(localized: "karaoke_ai_downloading"), fraction)
        case .failed:
            reasonText(session.separation.modelFailureReason
                ?? String(localized: "karaoke_ai_model_failed"))
        case .ready:
            songStatus
        }
    }

    @ViewBuilder
    private var songStatus: some View {
        switch session.currentSeparationState {
        case .separating(let fraction):
            progress(
                isCooling ? String(localized: "karaoke_ai_cooling") : String(localized: "karaoke_ai_separating"),
                fraction
            )
        case .ready where session.isStemLocked:
            Label("karaoke_ai_active", systemImage: "checkmark.circle.fill")
        case .ready:
            Text("karaoke_ai_aligning")
        case .unsupported:
            reasonText(String(localized: "karaoke_ai_unsupported_song"))
        case .failed:
            reasonText(session.currentSeparationFailureReason.map {
                String(format: String(localized: "karaoke_ai_failed_format"), $0)
            } ?? String(localized: "karaoke_ai_failed"))
        case .idle, nil:
            Text("karaoke_ai_preparing")
        }
    }

    private func reasonText(_ text: String) -> some View {
        Text(text)
            .lineLimit(2)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var isCooling: Bool {
        session.songID.map { session.separation.coolingSongIDs.contains($0) } ?? false
    }

    private func progress(_ title: String, _ fraction: Double) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .lineLimit(1)
            ProgressView(value: fraction)
                .frame(width: 90)
                .tint(.white)
            Text(fraction, format: .percent.precision(.fractionLength(0)))
                .monospacedDigit()
        }
    }
}

/// Stage options, and housekeeping for the AI model and its cache.
private struct KaraokeStageMenu: View {
    @Bindable var session: KaraokeSession
    @State private var cacheSize: Int64 = 0

    var body: some View {
        Menu {
            Toggle(isOn: $session.vocalAssistEnabled) {
                Text("karaoke_vocal_assist")
                Text("karaoke_vocal_assist_detail")
            }
            if session.separation.modelState != .unsupportedSystem {
                Divider()
                aiHousekeeping
            }
        } label: {
            ImmersiveGlassActionLabel(symbol: "ellipsis", diameter: 40)
        }
        #if os(macOS)
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        #endif
        .accessibilityLabel(Text("more"))
        .onAppear { cacheSize = session.separation.cacheSizeBytes() }
    }

    @ViewBuilder
    private var aiHousekeeping: some View {
        Button(role: .destructive) {
            session.separation.clearCache()
            cacheSize = 0
        } label: {
            Label(
                String(
                    format: String(localized: "karaoke_ai_clear_cache_format"),
                    ByteCountFormatter.string(fromByteCount: cacheSize, countStyle: .file)
                ),
                systemImage: "trash"
            )
        }
        if session.separation.modelState == .ready {
            Button(role: .destructive) {
                Task {
                    await session.separation.removeModel()
                    // 模型没了开关就不该还亮着；再打开会重新下载。
                    session.aiSeparationEnabled = false
                }
            } label: {
                Label("karaoke_ai_remove_model", systemImage: "xmark.bin")
            }
        }
    }
}

/// The lines being looped, with a way to take in the next one. Sized to sit
/// in the 22-point times row under the progress bar.
private struct KaraokeLoopChip: View {
    let session: KaraokeSession
    let lineCount: Int

    var body: some View {
        HStack(spacing: 6) {
            Label(
                String(format: String(localized: "karaoke_loop_lines_format"), lineCount),
                systemImage: "repeat"
            )
            .font(.caption2.weight(.semibold))
            .lineLimit(1)
            if session.canExtendLoop {
                Button(action: session.extendLoop) {
                    Label("karaoke_loop_extend", systemImage: "plus")
                        .font(.caption2.weight(.semibold))
                        .lineLimit(1)
                        .padding(.horizontal, 7)
                        .frame(height: 18)
                        .background(.white.opacity(0.16), in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .foregroundStyle(.white.opacity(0.92))
        .padding(.leading, 9)
        .padding(.trailing, session.canExtendLoop ? 2 : 9)
        .frame(height: 22)
        .karaokeGlass(Capsule())
    }
}

/// 点了暂时用不了的「结算」「录音」后，说明还差哪一步。
private struct KaraokeHintChip: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "info.circle")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white.opacity(0.92))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, 9)
            .frame(height: 22)
            .karaokeGlass(Capsule())
    }
}

private extension KaraokeSession.TransportHint {
    var message: String {
        switch self {
        case .finishNeedsMicrophone: String(localized: "karaoke_finish_needs_microphone")
        case .finishNeedsSinging: String(localized: "karaoke_finish_needs_singing")
        case .recordNeedsMicrophone: String(localized: "karaoke_record_needs_microphone")
        case .practicing: String(localized: "karaoke_practice_not_scored")
        }
    }
}

/// 「原唱带唱中」：贴在音准线一角，不占布局。
private struct KaraokeAssistBadge: View {
    var body: some View {
        Label("karaoke_vocal_assist_active", systemImage: "person.wave.2.fill")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white.opacity(0.92))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .karaokeGlass(Capsule())
    }
}

/// A labelled minus/plus pair, for the key and the practice speed.
private struct KaraokeStepper: View {
    let titleKey: LocalizedStringKey
    let value: String
    let downLabel: LocalizedStringKey
    let upLabel: LocalizedStringKey
    let canStepDown: Bool
    let canStepUp: Bool
    let stepDown: () -> Void
    let stepUp: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(spacing: 0) {
            Button(action: stepDown) {
                Image(systemName: "minus")
                    .font(.footnote.weight(.bold))
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            .disabled(!canStepDown)
            .accessibilityLabel(Text(downLabel))

            VStack(spacing: 0) {
                Text(titleKey)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.6))
                Text(value)
                    .font(.subheadline.monospacedDigit().weight(.semibold))
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)

            Button(action: stepUp) {
                Image(systemName: "plus")
                    .font(.footnote.weight(.bold))
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            .disabled(!canStepUp)
            .accessibilityLabel(Text(upLabel))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .opacity(isEnabled ? 1 : 0.4)
        .background(.white.opacity(0.08), in: Capsule())
        .frame(maxWidth: .infinity)
    }
}


private struct KaraokeScoreBadge: View {
    let score: Int

    var body: some View {
        VStack(spacing: 0) {
            Text("\(score)")
                .font(.system(size: 20, weight: .heavy, design: .rounded).monospacedDigit())
                .contentTransition(.numericText(value: Double(score)))
            Text("karaoke_score")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.6))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .frame(height: 44)
        .karaokeGlass(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

private struct KaraokeNotice: View {
    let systemImage: String
    let message: String
    var actionTitle: String?
    var action: () -> Void = {}

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.white.opacity(0.6))
            Text(message)
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.85))
            if let actionTitle {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .tint(.white)
                    .foregroundStyle(.black)
            }
        }
        .padding(28)
        .frame(maxWidth: 420)
    }
}

/// 与播放页深色外观同一套氛围底：封面取色的缓动色场，再压一层保证白字可读的暗幕。
/// 卡拉OK的歌词比播放页大、停留久，暗幕在中段再加深一点。
private struct KaraokeStageBackdrop: View {
    let isPlaying: Bool

    @Environment(ThemeService.self) private var theme
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorSchemeContrast) private var contrast

    private static let baseColor = Color(red: 0.035, green: 0.043, blue: 0.055)

    var body: some View {
        let hasArtwork = theme.hasArtworkAmbient
        let primaryOpacity = hasArtwork ? 0.88 : 0.34
        let secondaryOpacity = hasArtwork ? 0.70 : 0.26
        let overlay = NowPlayingAmbientLegibilityPolicy.darkOverlay(
            paletteLuminance: hasArtwork ? theme.artworkLuminance : 0.18,
            primaryOpacity: primaryOpacity,
            secondaryOpacity: secondaryOpacity,
            usesIncreasedContrast: contrast == .increased
        )

        ZStack {
            AdaptiveNowPlayingBackdrop(
                baseColor: Self.baseColor,
                primaryAccent: theme.accentColor,
                secondaryAccent: theme.secondaryAccent,
                darkAccent: theme.darkAccent,
                primaryOpacity: primaryOpacity,
                secondaryOpacity: secondaryOpacity,
                hasArtworkPalette: hasArtwork,
                isVisible: true,
                isSceneActive: scenePhase == .active,
                isPlaying: isPlaying,
                paletteVibrancy: hasArtwork ? theme.artworkVibrancy : 0,
                paletteLuminance: hasArtwork ? theme.artworkLuminance : 0.18
            )
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(overlay.topOpacity), location: 0),
                    .init(color: .black.opacity(min(0.9, overlay.middleOpacity + 0.12)), location: 0.5),
                    .init(color: .black.opacity(overlay.bottomOpacity), location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .animation(.easeInOut(duration: 0.5), value: theme.colorID)
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// 播放页深色玻璃的平面版：材质 + 轻压暗 + 细白描边。卡片、胶囊、圆钮共用。
private struct KaraokeGlass<S: InsettableShape>: ViewModifier {
    let shape: S

    func body(content: Content) -> some View {
        content
            .background {
                shape.fill(.ultraThinMaterial)
                    .environment(\.colorScheme, .dark)
                shape.fill(.black.opacity(0.16))
            }
            .overlay {
                shape.strokeBorder(.white.opacity(0.14), lineWidth: 0.8)
            }
    }
}

extension View {
    fileprivate func karaokeGlass<S: InsettableShape>(_ shape: S) -> some View {
        modifier(KaraokeGlass(shape: shape))
    }
}

// MARK: - Result

private struct KaraokeResultView: View {
    let performance: KaraokePerformance
    let session: KaraokeSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 20) {
            Text("karaoke_result_title")
                .font(.headline)
                .foregroundStyle(.secondary)
            VStack(spacing: 4) {
                Text(performance.songTitle)
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                if !performance.artistName.isEmpty {
                    Text(performance.artistName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("\(performance.summary.totalScore)")
                    .font(.system(size: 72, weight: .heavy, design: .rounded).monospacedDigit())
                Text(performance.summary.grade.rawValue.uppercased())
                    .font(.system(size: 40, weight: .black, design: .rounded))
                    .foregroundStyle(gradeColor)
            }
            .accessibilityElement(children: .combine)
            Text(String(format: String(localized: "karaoke_lines_judged_format"), performance.summary.lines.count))
                .font(.footnote)
                .foregroundStyle(.secondary)
            if let best = performance.bestLineText, !best.isEmpty {
                VStack(spacing: 6) {
                    Text("karaoke_best_line")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("“\(best)”")
                        .font(.body.italic())
                        .multilineTextAlignment(.center)
                }
                .padding(14)
                .frame(maxWidth: .infinity)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            if session.isMixingRecording, performance.recordingURL == nil {
                ProgressView {
                    Text("karaoke_mixing")
                        .font(.footnote)
                }
            } else if let url = performance.recordingURL {
                HStack(spacing: 12) {
                    ShareLink(item: url) {
                        Label("karaoke_share_recording", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    Button(role: .destructive) {
                        session.deleteRecording(at: url)
                    } label: {
                        Label("karaoke_delete_recording", systemImage: "trash")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }
            Button("done") { dismiss() }
                .buttonStyle(.bordered)
        }
        .padding(24)
        .frame(maxWidth: 480)
        #if os(macOS)
        .frame(minWidth: 420)
        #else
        .presentationDetents([.medium, .large])
        #endif
    }

    private var gradeColor: Color {
        switch performance.summary.grade {
        case .s: .yellow
        case .a: .green
        case .b: .teal
        case .c: .orange
        case .d: .gray
        }
    }
}
