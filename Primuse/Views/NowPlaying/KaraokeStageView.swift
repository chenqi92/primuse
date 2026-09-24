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
                Color.black
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

private struct KaraokeStageContent: View {
    @Bindable var session: KaraokeSession
    let onClose: () -> Void

    private var player: AudioPlayerService { session.player }

    var body: some View {
        ZStack {
            KaraokeStageBackground()
            VStack(spacing: 0) {
                header
                Spacer(minLength: 12)
                stage
                Spacer(minLength: 12)
                if session.microphoneState == .on {
                    KaraokePitchLane(points: session.pitchHistory)
                        .frame(height: 72)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 8)
                        .transition(.opacity)
                }
                KaraokeControlPanel(session: session)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: session.microphoneState)
        .sheet(item: $session.completedPerformance) { performance in
            KaraokeResultView(performance: performance, session: session)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .background(.white.opacity(0.12), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("close"))
            .keyboardShortcut(.cancelAction)

            VStack(alignment: .leading, spacing: 2) {
                Text(player.currentSong?.title ?? String(localized: "karaoke_title"))
                    .font(.headline)
                    .lineLimit(1)
                if let artist = player.currentSong?.artistName, !artist.isEmpty {
                    Text(artist)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                }
                if let source = session.lyricsBorrowedFromTitle {
                    Text(String(format: String(localized: "karaoke_lyrics_from_format"), source))
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if let score = session.runningScore {
                KaraokeScoreBadge(score: score)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .animation(.spring(duration: 0.3), value: session.runningScore)
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
            .padding(.horizontal, 20)
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

// MARK: - Lyrics

private struct KaraokeLyricsStage: View {
    let session: KaraokeSession
    let time: TimeInterval
    let isPlaying: Bool

    private static let primaryColor = Color(red: 0.42, green: 0.86, blue: 1.0)
    private static let secondaryColor = Color(red: 1.0, green: 0.55, blue: 0.78)

    var body: some View {
        let windows = session.windows
        let activeIndex = KaraokeLineWindowPolicy.activeWindowIndex(in: windows, at: time)
        // Between rows the upcoming row takes the stage, waiting to be swept.
        let focusIndex = activeIndex ?? windows.firstIndex(where: { $0.start > time }) ?? (windows.count - 1)
        let leadIn = KaraokeLeadInPolicy.leadIn(windows: windows, at: time)

        VStack(spacing: 18) {
            if focusIndex > 0 {
                row(windowIndex: focusIndex - 1, role: .previous)
            }
            KaraokeLeadInDots(leadIn: leadIn)
            row(windowIndex: focusIndex, role: activeIndex == nil ? .upcoming : .current)
            if focusIndex + 1 < windows.count {
                row(windowIndex: focusIndex + 1, role: .next)
            }
        }
        .frame(maxWidth: 900)
        .animation(.easeInOut(duration: 0.35), value: focusIndex)
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
    private func row(windowIndex: Int, role: Role) -> some View {
        let window = session.windows[windowIndex]
        let line = session.stageLines[window.lineIndex]
        let isDuet = session.hasDuetParts
        let voiceColor = window.voice == .secondary ? Self.secondaryColor : Self.primaryColor
        let isMine = !isDuet || session.part == .all
            || (session.part == .primary) == (window.voice == .primary)
        let side = Self.side(isDuet: isDuet, voice: window.voice)

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
                    fontSize: 34,
                    weight: .bold,
                    activeStyle: AnyShapeStyle(voiceColor),
                    inactiveColor: .white.opacity(isMine ? 0.85 : 0.5),
                    textAlignment: side.text,
                    timeAt: { _ in time },
                    fixedTime: time,
                    isPlaybackActive: isPlaying,
                    animatesSyllableBounce: isPlaying
                )
            case .previous, .next:
                Text(line.text)
                    .font(.system(size: role == .next ? 22 : 18, weight: .semibold))
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
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityHidden(true)
    }
}

// MARK: - Controls

private struct KaraokeControlPanel: View {
    @Bindable var session: KaraokeSession

    private var player: AudioPlayerService { session.player }

    var body: some View {
        VStack(spacing: 14) {
            if let status = statusMessage {
                HStack(spacing: 8) {
                    Label(status, systemImage: "info.circle")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.75))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let url = session.lastRecordingURL, !session.isMixingRecording {
                        ShareLink(item: url) {
                            Label("karaoke_share_recording", systemImage: "square.and.arrow.up")
                                .font(.footnote.weight(.semibold))
                        }
                        .foregroundStyle(.white)
                    }
                }
            }

            HStack(spacing: 12) {
                Image(systemName: "person.slash")
                    .foregroundStyle(.white.opacity(0.6))
                    .accessibilityHidden(true)
                Slider(value: $session.vocalLevel, in: 0...1)
                    .tint(.white)
                    .accessibilityLabel(Text("karaoke_vocals"))
                    .accessibilityValue(Text(session.vocalLevel, format: .percent.precision(.fractionLength(0))))
                Image(systemName: "person.wave.2.fill")
                    .foregroundStyle(.white.opacity(0.6))
                    .accessibilityHidden(true)
            }
            .disabled(session.availability != .available || session.isPlayingInstrumental)

            HStack(spacing: 10) {
                keyStepper
                if session.canToggleBackingTrack || session.isSwitchingTrack {
                    backingTrackButton
                }
                if session.hasDuetParts {
                    Picker(selection: $session.part) {
                        Text("karaoke_part_all").tag(KaraokePart.all)
                        Text("karaoke_part_primary").tag(KaraokePart.primary)
                        Text("karaoke_part_secondary").tag(KaraokePart.secondary)
                    } label: {
                        Text("karaoke_part")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            }

            HStack(spacing: 10) {
                KaraokeToolButton(
                    titleKey: "karaoke_microphone",
                    systemImage: session.microphoneState == .on ? "mic.fill" : "mic",
                    isOn: session.microphoneState == .on,
                    isBusy: session.microphoneState == .starting,
                    action: session.toggleMicrophone
                )
                KaraokeToolButton(
                    titleKey: "karaoke_monitor",
                    systemImage: "headphones",
                    isOn: session.isMonitoring,
                    action: { session.isMonitoring.toggle() }
                )
                .disabled(session.microphoneState != .on || !session.canMonitor)
                KaraokeToolButton(
                    titleKey: session.isRecording
                        ? LocalizedStringKey("karaoke_stop_recording")
                        : LocalizedStringKey("karaoke_record"),
                    systemImage: session.isRecording ? "stop.circle.fill" : "record.circle",
                    isOn: session.isRecording,
                    tint: .red,
                    isBusy: session.isMixingRecording,
                    action: session.toggleRecording
                )
                .disabled(!session.isRecording && !session.canRecord)
                KaraokeToolButton(
                    titleKey: "karaoke_finish",
                    systemImage: "flag.checkered",
                    isOn: false,
                    action: session.finishPerformance
                )
                .disabled(session.runningScore == nil)
                Button {
                    player.togglePlayPause()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .frame(width: 56, height: 56)
                        .background(.white, in: Circle())
                        .foregroundStyle(.black)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(player.isPlaying ? LocalizedStringKey("pause") : LocalizedStringKey("play")))
                .keyboardShortcut(.space, modifiers: [])
            }
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .environment(\.colorScheme, .dark)
    }

    private var keyStepper: some View {
        HStack(spacing: 0) {
            Button {
                session.keyShift -= 1
            } label: {
                Image(systemName: "minus")
                    .frame(width: 36, height: 32)
                    .contentShape(Rectangle())
            }
            .disabled(session.keyShift <= KaraokeKeyShiftPolicy.range.lowerBound)
            .accessibilityLabel(Text("karaoke_key_down"))

            VStack(spacing: 0) {
                Text("karaoke_key")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.6))
                Text(keyLabel)
                    .font(.subheadline.monospacedDigit().weight(.semibold))
            }
            .frame(minWidth: 58)
            .accessibilityElement(children: .combine)

            Button {
                session.keyShift += 1
            } label: {
                Image(systemName: "plus")
                    .frame(width: 36, height: 32)
                    .contentShape(Rectangle())
            }
            .disabled(session.keyShift >= KaraokeKeyShiftPolicy.range.upperBound)
            .accessibilityLabel(Text("karaoke_key_up"))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .padding(.horizontal, 4)
        .background(.white.opacity(0.1), in: Capsule())
        .disabled(session.availability != .available)
    }

    private var backingTrackButton: some View {
        Button(action: session.toggleBackingTrack) {
            HStack(spacing: 6) {
                if session.isSwitchingTrack {
                    ProgressView().controlSize(.small).tint(.white)
                } else {
                    Image(systemName: session.isPlayingInstrumental ? "checkmark.circle.fill" : "music.quarternote.3")
                }
                Text("karaoke_backing_track")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
            }
            .padding(.horizontal, 14)
            .frame(height: 40)
            .background(
                session.isPlayingInstrumental ? AnyShapeStyle(.white) : AnyShapeStyle(.white.opacity(0.1)),
                in: Capsule()
            )
            .foregroundStyle(session.isPlayingInstrumental ? .black : .white)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(session.isSwitchingTrack)
        .accessibilityAddTraits(session.isPlayingInstrumental ? .isSelected : [])
    }

    private var keyLabel: String {
        session.keyShift == 0
            ? String(localized: "karaoke_key_original")
            : String(format: "%+d", session.keyShift)
    }

    private var statusMessage: String? {
        if session.isPlayingInstrumental { return String(localized: "karaoke_backing_track_playing") }
        if session.isEffectivelyMono { return String(localized: "karaoke_mono_warning") }
        switch session.microphoneState {
        case .denied: return String(localized: "karaoke_mic_denied")
        case .unavailable: return String(localized: "karaoke_mic_unavailable")
        case .on where !session.canMonitor: return String(localized: "karaoke_monitor_needs_wired")
        default: break
        }
        if session.isMixingRecording { return String(localized: "karaoke_mixing") }
        if session.recordingFailed { return String(localized: "karaoke_recording_failed") }
        if session.lastRecordingURL != nil { return String(localized: "karaoke_recording_saved") }
        return nil
    }
}

private struct KaraokeToolButton: View {
    let titleKey: LocalizedStringKey
    let systemImage: String
    let isOn: Bool
    var tint: Color = .white
    var isBusy = false
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                ZStack {
                    if isBusy {
                        ProgressView().controlSize(.small).tint(.white)
                    } else {
                        Image(systemName: systemImage)
                            .font(.system(size: 18, weight: .semibold))
                    }
                }
                .frame(width: 44, height: 44)
                .background(isOn ? tint.opacity(0.9) : .white.opacity(0.12), in: Circle())
                .foregroundStyle(isOn ? (tint == .white ? .black : .white) : .white)
                Text(titleKey)
                    .font(.caption2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .foregroundStyle(.white.opacity(0.8))
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.4)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

private struct KaraokeScoreBadge: View {
    let score: Int

    var body: some View {
        VStack(spacing: 0) {
            Text("\(score)")
                .font(.system(size: 22, weight: .heavy, design: .rounded).monospacedDigit())
                .contentTransition(.numericText(value: Double(score)))
            Text("karaoke_score")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.6))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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

private struct KaraokeStageBackground: View {
    var body: some View {
        LinearGradient(
            colors: [
                Color(red: 0.09, green: 0.05, blue: 0.2),
                Color(red: 0.02, green: 0.02, blue: 0.06),
                Color(red: 0.12, green: 0.03, blue: 0.14),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
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
