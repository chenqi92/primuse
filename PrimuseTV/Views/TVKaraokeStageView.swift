#if os(tvOS)
import PrimuseKit
import SwiftUI

/// Karaoke on the big screen: lyrics swept as they are sung, the vocal level,
/// and an iPhone joining through the QR code to score the singing.
struct TVKaraokeStageView: View {
    @Environment(TVStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var session: TVKaraokeSession?

    var body: some View {
        ZStack {
            TVAmbientBackdrop(
                tint: store.nowPlayingPresentationColors.primary,
                tint2: store.nowPlayingPresentationColors.secondary,
                strength: 0.6
            )
            TVColor.bg.opacity(0.6).ignoresSafeArea()
            if let session {
                TVKaraokeStageContent(session: session)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            guard session == nil else { return }
            let created = TVKaraokeSession(store: store)
            session = created
            created.start()
        }
        .onDisappear { session?.stop() }
        .onExitCommand { dismiss() }
    }
}

struct TVKaraokeStageContent: View {
    @Bindable var session: TVKaraokeSession
    @Environment(\.dismiss) private var dismiss
    @State private var showsMicrophone = false
    private var store: TVStore { session.store }

    var body: some View {
        VStack(spacing: 28) {
            header
            HStack(spacing: 64) {
                VStack(spacing: 28) {
                    Spacer(minLength: 0)
                    lyrics
                    Spacer(minLength: 0)
                    if session.isMicConnected {
                        TVKaraokePitchLane(points: session.pitchHistory)
                            .frame(height: 84)
                    }
                    progress
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                ScrollView {
                    controls.padding(12)
                }
                .frame(width: 520)
                .focusSection()
            }
        }
        .padding(.horizontal, 80)
        .padding(.vertical, 54)
        .background(.black.opacity(0.35))
        .foregroundStyle(.white)
        .sheet(isPresented: $showsMicrophone) {
            VStack(spacing: 40) {
                micPanel
                actionButton("done", symbol: "checkmark") { showsMicrophone = false }
            }
            .padding(70)
            .frame(maxWidth: 850)
            .onExitCommand { showsMicrophone = false }
        }
        .overlay {
            if let summary = session.completedSummary {
                TVKaraokeResultCard(summary: summary) { session.completedSummary = nil }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 24) {
            stepButton(systemImage: "chevron.down", label: "close", enabled: true) { dismiss() }
            TVArtworkView(coverKey: store.nowPlaying.albumID, artist: store.nowPlaying.artist,
                          album: store.nowPlaying.album, songID: store.nowPlaying.songID,
                          coverRef: store.nowPlaying.coverRef, tint: store.nowPlaying.tint,
                          tint2: store.nowPlaying.tint2, glyph: store.nowPlaying.glyph, size: 76, radius: 14)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(store.nowPlaying.title)
                    .tvFont(size: 36, weight: .bold, relativeTo: .title)
                    .lineLimit(1)
                Text(subtitle)
                    .tvFont(.caption)
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }
            Spacer()
            if let score = session.runningScore, !session.isPracticing {
                VStack(spacing: 0) {
                    Text("\(score)")
                        .tvFont(size: 52, weight: .bold, design: .rounded, relativeTo: .largeTitle)
                        .monospacedDigit()
                    Text(String(localized: "karaoke_score"))
                        .tvFont(.caption).foregroundStyle(.white.opacity(0.6))
                }
            }
        }
    }

    private var subtitle: String {
        var parts = [store.nowPlaying.artist]
        if let title = session.lyricsBorrowedFromTitle {
            parts.append(String(format: String(localized: "karaoke_lyrics_from_format"), title))
        } else if session.usesInferredWordTiming {
            parts.append(String(localized: "karaoke_ai_word_timing"))
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    @ViewBuilder
    private var lyrics: some View {
        if session.windows.isEmpty {
            Text(String(localized: "karaoke_no_lyrics"))
                .tvFont(.sectionTitle)
                .foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !store.isPlaying)) { context in
                TVKaraokeLyrics(session: session, time: store.interpolatedTime(at: context.date))
            }
        }
    }

    private var progress: some View {
        VStack(spacing: 12) {
            ProgressView(value: min(store.currentTime, max(1, store.duration)), total: max(1, store.duration))
                .tint(.white)
            HStack {
                Text(store.currentTime.formattedDuration)
                Spacer()
                Text(store.duration.formattedDuration)
            }
            .tvFont(.caption).monospacedDigit().foregroundStyle(.white.opacity(0.5))
        }
    }

    private var controls: some View {
        VStack(spacing: 22) {
            HStack(spacing: 26) {
                stepButton(systemImage: "backward.end.fill", label: "a11y_previous_track", enabled: true) { store.previous() }
                stepButton(systemImage: store.isPlaying ? "pause.fill" : "play.fill",
                           label: store.isPlaying ? "pause" : "play", enabled: true) { store.togglePlayPause() }
                stepButton(systemImage: "forward.end.fill", label: "a11y_next_track", enabled: true) { store.next() }
            }
            .frame(maxWidth: .infinity)
            VStack(spacing: 22) {
                adjustment("karaoke_vocals", value: session.vocalLevel.formatted(.percent.precision(.fractionLength(0))),
                           downLabel: "karaoke_vocals", upLabel: "karaoke_vocals",
                           canDown: session.isVocalReductionAvailable && !session.isPlayingInstrumental && session.vocalLevel > 0,
                           canUp: session.isVocalReductionAvailable && !session.isPlayingInstrumental && session.vocalLevel < 1,
                           down: { session.vocalLevel -= 0.1 }, up: { session.vocalLevel += 0.1 })
                adjustment("karaoke_key", value: session.keyShift == 0 ? String(localized: "karaoke_key_original") : String(format: "%+d", session.keyShift),
                           downLabel: "karaoke_key_down", upLabel: "karaoke_key_up",
                           canDown: session.isVocalReductionAvailable && session.keyShift > KaraokeKeyShiftPolicy.range.lowerBound,
                           canUp: session.isVocalReductionAvailable && session.keyShift < KaraokeKeyShiftPolicy.range.upperBound,
                           down: { session.keyShift -= 1 }, up: { session.keyShift += 1 })
                adjustment("karaoke_speed", value: session.practiceRate == 1 ? String(localized: "karaoke_speed_normal") : String(format: "%.1f×", session.practiceRate),
                           downLabel: "karaoke_speed_down", upLabel: "karaoke_speed_up",
                           canDown: session.canPractice && session.practiceRate > 0.5,
                           canUp: session.canPractice && session.practiceRate < 1,
                           down: { session.practiceRate = KaraokePracticePolicy.stepped(session.practiceRate, up: false) },
                           up: { session.practiceRate = KaraokePracticePolicy.stepped(session.practiceRate, up: true) })
            }
            .padding(24)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 30))
            actionButton(session.loop == nil ? "karaoke_loop" : "karaoke_loop_stop", symbol: "repeat", selected: session.loop != nil,
                         enabled: session.canPractice && !session.windows.isEmpty, action: session.toggleLoop)
            if let loop = session.loop {
                Text(String(format: String(localized: "karaoke_loop_lines_format"), loop.lineCount))
                    .tvFont(.caption).foregroundStyle(.white.opacity(0.6))
                actionButton("karaoke_loop_extend", symbol: "plus", enabled: session.canExtendLoop, action: session.extendLoop)
            }
            if session.canToggleBackingTrack || session.isSwitchingTrack && session.instrumentalCompanion != nil {
                actionButton("karaoke_backing_track", symbol: "music.note", selected: session.isPlayingInstrumental,
                             enabled: session.canToggleBackingTrack, action: session.toggleBackingTrack)
            }
            actionButton("karaoke_vocal_assist", symbol: "person.wave.2", selected: session.vocalAssistEnabled,
                         enabled: session.isMicConnected && session.isVocalReductionAvailable && !session.isPlayingInstrumental) {
                session.vocalAssistEnabled.toggle()
            }
            if session.hasDuetParts {
                HStack(spacing: 12) {
                    partButton(.all, "karaoke_part_all")
                    partButton(.primary, "karaoke_part_primary")
                    partButton(.secondary, "karaoke_part_secondary")
                }
            }
            localAIControls
            if let notice {
                Text(notice).tvFont(.caption).foregroundStyle(.white.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
            }
            actionButton("karaoke_microphone", symbol: "mic.fill", selected: session.isMicConnected) { showsMicrophone = true }
            if session.runningScore != nil, !session.isPracticing {
                actionButton("karaoke_finish", symbol: "flag.checkered", action: session.finishPerformance)
            }
        }
    }

    private func adjustment(_ title: String.LocalizationValue, value: String,
                            downLabel: String.LocalizationValue, upLabel: String.LocalizationValue,
                            canDown: Bool, canUp: Bool,
                            down: @escaping () -> Void, up: @escaping () -> Void) -> some View {
        HStack(spacing: 18) {
            stepButton(systemImage: "minus", label: downLabel, enabled: canDown, action: down)
            VStack(spacing: 4) {
                Text(String(localized: title)).tvFont(.caption).foregroundStyle(.white.opacity(0.55))
                Text(value).tvFont(.cardTitle).monospacedDigit()
            }
            .frame(maxWidth: .infinity)
            stepButton(systemImage: "plus", label: upLabel, enabled: canUp, action: up)
        }
    }

    private func actionButton(_ title: String.LocalizationValue, symbol: String, selected: Bool = false,
                              enabled: Bool = true, action: @escaping () -> Void) -> some View {
        TVFocusButton(radius: 28, scale: 1.03, lift: 2, action: action) { _ in
            HStack(spacing: 14) {
                Image(systemName: symbol)
                Text(String(localized: title))
                Spacer(minLength: 0)
                if selected { Image(systemName: "checkmark") }
            }
            .tvFont(.button)
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity, minHeight: 64)
            .background(selected ? .white.opacity(0.12) : .black.opacity(0.3), in: RoundedRectangle(cornerRadius: 28))
            .overlay(RoundedRectangle(cornerRadius: 28).strokeBorder(.white.opacity(0.08)))
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder
    private var localAIControls: some View {
        if session.separation.modelState != .unsupportedSystem {
            VStack(alignment: .leading, spacing: 16) {
                actionButton("karaoke_tv_ai_local", symbol: "waveform", selected: session.localAIEnabled,
                             enabled: session.isVocalReductionAvailable && session.currentSong != nil && !session.isPlayingInstrumental) {
                    session.localAIEnabled.toggle()
                }
                if session.localAIEnabled {
                    localAIStatus
                } else if session.separation.modelState == .notDownloaded {
                    Text(String(format: String(localized: "karaoke_ai_download_on_enable_format"), modelSize))
                        .tvFont(.caption)
                        .foregroundStyle(TVColor.textMuted)
                }
            }
        }
    }

    private var modelSize: String {
        ByteCountFormatter.string(fromByteCount: KaraokeVocalModel.approximateDownloadBytes, countStyle: .file)
    }

    @ViewBuilder
    private var localAIStatus: some View {
        switch session.separation.modelState {
        case .downloading(let fraction):
            aiProgress(String(localized: "karaoke_ai_downloading"), fraction: fraction)
        case .failed:
            aiRetry
            if let reason = session.separation.modelFailureReason {
                Text(reason).tvFont(.caption).foregroundStyle(TVColor.textMuted).lineLimit(3)
            }
        case .ready:
            if session.localStemLoadFailed {
                aiRetry
            } else if let song = session.currentSong, !session.usesPhoneStem {
                switch session.separation.state(for: song) {
                case .separating(let fraction):
                    aiProgress(String(localized: session.separation.coolingSongIDs.contains(song.id)
                                      ? "karaoke_ai_cooling" : "karaoke_ai_separating"), fraction: fraction)
                case .failed:
                    aiRetry
                case .unsupported:
                    Text(String(localized: "karaoke_ai_unsupported_song")).tvFont(.caption)
                case .ready:
                    Text(String(localized: session.usesLocalStem ? "karaoke_ai_active" : "karaoke_ai_preparing"))
                        .tvFont(.caption)
                case .idle:
                    Text(String(localized: "karaoke_ai_preparing")).tvFont(.caption)
                }
            }
        case .notDownloaded, .unsupportedSystem:
            EmptyView()
        }
    }

    private func aiProgress(_ title: String, fraction: Double) -> some View {
        HStack(spacing: 12) {
            ProgressView(value: fraction).frame(width: 140)
            Text(title).tvFont(.caption)
            Text(fraction, format: .percent.precision(.fractionLength(0)))
                .tvFont(.caption).monospacedDigit()
        }
    }

    private var aiRetry: some View {
        TVFocusButton(radius: 18, scale: 1.05, lift: 4, action: session.retryLocalSeparation) { _ in
            Text(String(localized: "karaoke_ai_retry"))
                .tvFont(.button).padding(.horizontal, 24).frame(height: 64)
        }
    }

    private func partButton(_ part: KaraokePart, _ key: String.LocalizationValue) -> some View {
        let selected = session.part == part
        return TVFocusButton(radius: 18, scale: 1.05, lift: 4, action: { session.part = part }) { _ in
            Text(String(localized: key))
                .tvFont(.button)
                .padding(.horizontal, 24)
                .frame(height: 72)
                .background(selected ? TVColor.text.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 18))
        }
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private var notice: String? {
        if session.isPracticing { return String(localized: "karaoke_practice_not_scored") }
        if session.isPlayingInstrumental { return String(localized: "karaoke_backing_track_playing") }
        if session.isVocalAssistSuppressed { return String(localized: "karaoke_vocal_assist_paused") }
        if session.isVocalAssisting { return String(localized: "karaoke_vocal_assist_active") }
        if !session.isVocalReductionAvailable {
            return String(localized: "karaoke_tv_unsupported")
        }
        if session.usesPhoneStem {
            return String(localized: "karaoke_tv_ai_active")
        }
        if session.usesLocalStem { return nil }
        if let progress = session.phoneSeparationProgress {
            return String(format: String(localized: "karaoke_tv_ai_preparing_format"), Int((progress * 100).rounded()))
        }
        if session.isEffectivelyMono {
            return String(localized: "karaoke_mono_warning")
        }
        return nil
    }

    private func stepButton(systemImage: String, label: String.LocalizationValue, enabled: Bool, action: @escaping () -> Void) -> some View {
        TVFocusButton(radius: 36, scale: 1.08, lift: 4, action: action) { _ in
            Image(systemName: systemImage)
                .font(.system(size: 30, weight: .bold))
                .frame(width: 72, height: 72)
                .background(.black.opacity(0.3), in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.1)))
        }
        .disabled(!enabled)
        .accessibilityLabel(Text(String(localized: label)))
        .opacity(enabled ? 1 : 0.4)
    }

    @ViewBuilder
    private var micPanel: some View {
        switch session.micServer.state {
        case .listening(let endpoint):
            HStack(spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(String(localized: "karaoke_tv_scan_title"))
                        .tvFont(.cardTitle)
                        .foregroundStyle(TVColor.text)
                    Text(String(localized: "karaoke_tv_scan_hint"))
                        .tvFont(.caption)
                        .foregroundStyle(TVColor.textMuted)
                        .frame(maxWidth: 420, alignment: .leading)
                }
                TVQRCode(content: endpoint.url.absoluteString, size: 190)
            }
            .padding(24)
            .tvPanel(radius: 24)
        case .connected(let deviceName, _):
            Label(
                String(format: String(localized: "karaoke_tv_mic_connected_format"), deviceName),
                systemImage: "mic.fill"
            )
            .tvFont(.body)
            .foregroundStyle(TVColor.text)
            .padding(.horizontal, 28)
            .padding(.vertical, 18)
            .tvPanel(radius: 20)
        case .idle, .failed:
            EmptyView()
        }
    }
}

private struct TVKaraokeLyrics: View {
    let session: TVKaraokeSession
    let time: TimeInterval

    var body: some View {
        let windows = session.windows
        let active = KaraokeLineWindowPolicy.activeWindowIndex(in: windows, at: time)
        let focus = active ?? windows.firstIndex(where: { $0.start > time }) ?? (windows.count - 1)
        let leadIn = KaraokeLeadInPolicy.leadIn(windows: windows, at: time)

        VStack(spacing: 30) {
            if focus > 0 {
                plainLine(windows[focus - 1], size: 34, opacity: 0.3)
            }
            HStack(spacing: 16) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(TVColor.text.opacity(index < (leadIn?.remainingBeats ?? 0) ? 0.95 : 0.15))
                        .frame(width: 18, height: 18)
                }
            }
            .opacity(leadIn == nil ? 0 : 1)
            sweptLine(windows[focus])
            if focus + 1 < windows.count {
                plainLine(windows[focus + 1], size: 40, opacity: 0.5)
            }
        }
        .frame(maxWidth: .infinity)
        .animation(.easeInOut(duration: 0.35), value: focus)
    }

    private func plainLine(_ window: KaraokeLineWindow, size: CGFloat, opacity: Double) -> some View {
        Text(session.stageLines[window.lineIndex].text)
            .tvFont(size: size, weight: .semibold, relativeTo: .title2)
            .foregroundStyle(TVColor.text.opacity(opacity))
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .id(window.lineID)
    }

    /// Sung syllables in the accent colour, the one being sung fading in,
    /// the rest dim; one Text so long rows wrap naturally.
    private func sweptLine(_ window: KaraokeLineWindow) -> some View {
        let line = session.stageLines[window.lineIndex]
        let sung = window.voice == .secondary
            ? Color(red: 1.0, green: 0.62, blue: 0.80) : .white
        let mine = !session.hasDuetParts || session.part == .all
            || (session.part == .primary) == (window.voice == .primary)
        return VStack(spacing: 10) {
            if session.hasDuetParts, session.part != .all {
                Text(String(localized: mine ? "karaoke_you" : "karaoke_partner"))
                    .tvFont(.eyebrow)
                    .foregroundStyle(sung)
            }
            KaraokeLineView(line: line, fontSize: 58, weight: .bold,
                            activeStyle: AnyShapeStyle(sung), inactiveColor: .white.opacity(0.42),
                            textAlignment: session.hasDuetParts ? (window.voice == .secondary ? .trailing : .leading) : .center,
                            timeAt: { _ in time }, fixedTime: time,
                            isPlaybackActive: session.store.isPlaying,
                            animatesSyllableBounce: session.store.isPlaying)
                .opacity(mine ? 1 : 0.7)
        }
        .id(window.lineID)
    }
}

/// The last few seconds of melody (grey) against the singer (green on
/// pitch, orange off).
private struct TVKaraokePitchLane: View {
    let points: [TVKaraokeSession.PitchPoint]

    var body: some View {
        Canvas { context, size in
            guard let latest = points.last?.time else { return }
            let notes = points.flatMap { [$0.reference, $0.sung].compactMap { $0 } }
            let low = (notes.min() ?? 48) - 3
            let high = max(low + 12, (notes.max() ?? 72) + 3)
            let span = TVKaraokeSession.pitchHistoryDuration
            func x(_ t: TimeInterval) -> CGFloat { CGFloat((t - (latest - span)) / span) * size.width }
            func y(_ n: Double) -> CGFloat { size.height * CGFloat(1 - (n - low) / (high - low)) }
            for point in points {
                if let reference = point.reference {
                    let rect = CGRect(x: x(point.time) - 5, y: y(reference) - 4, width: 11, height: 8)
                    context.fill(Path(roundedRect: rect, cornerRadius: 4), with: .color(.white.opacity(0.3)))
                }
            }
            for point in points {
                guard let sung = point.sung else { continue }
                var shown = sung
                var onPitch = false
                if let reference = point.reference {
                    shown = sung - 12 * ((sung - reference) / 12).rounded()
                    onPitch = KaraokeScorer.pitchAccuracy(sung: sung, reference: reference) >= 0.8
                }
                let color: Color = point.reference == nil ? .white.opacity(0.7) : (onPitch ? .green : .orange)
                let rect = CGRect(x: x(point.time) - 6, y: y(shown) - 6, width: 12, height: 12)
                context.fill(Path(ellipseIn: rect), with: .color(color))
            }
        }
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18))
    }
}

private struct TVKaraokeResultCard: View {
    let summary: KaraokeScoreSummary
    let onDone: () -> Void

    var body: some View {
        ZStack {
            TVColor.bg.opacity(0.55).ignoresSafeArea()
            VStack(spacing: 24) {
                Text(String(localized: "karaoke_result_title"))
                    .tvFont(.sectionTitle)
                    .foregroundStyle(TVColor.textMuted)
                HStack(alignment: .firstTextBaseline, spacing: 20) {
                    Text("\(summary.totalScore)")
                        .tvFont(size: 140, weight: .heavy, design: .rounded, relativeTo: .largeTitle)
                        .monospacedDigit()
                    Text(summary.grade.rawValue.uppercased())
                        .tvFont(size: 80, weight: .black, design: .rounded, relativeTo: .largeTitle)
                        .foregroundStyle(.yellow)
                }
                .foregroundStyle(TVColor.text)
                Text(String(format: String(localized: "karaoke_lines_judged_format"), summary.lines.count))
                    .tvFont(.body)
                    .foregroundStyle(TVColor.textMuted)
                TVFocusButton(radius: 18, scale: 1.05, lift: 4, action: onDone) { _ in
                    Text(String(localized: "done"))
                        .tvFont(.button)
                        .padding(.horizontal, 48)
                        .frame(height: 72)
                }
            }
            .padding(60)
            .tvPanel(radius: 32)
        }
    }
}
#endif
