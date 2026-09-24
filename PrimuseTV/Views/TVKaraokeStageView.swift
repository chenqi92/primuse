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

private struct TVKaraokeStageContent: View {
    @Bindable var session: TVKaraokeSession
    private var store: TVStore { session.store }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 90)
                .padding(.top, 60)
            Spacer(minLength: 20)
            lyrics
                .padding(.horizontal, 140)
            Spacer(minLength: 20)
            if session.isMicConnected {
                TVKaraokePitchLane(points: session.pitchHistory)
                    .frame(height: 110)
                    .padding(.horizontal, 140)
                    .padding(.bottom, 24)
            }
            controls
                .padding(.horizontal, 90)
                .padding(.bottom, 60)
        }
        .overlay {
            if let summary = session.completedSummary {
                TVKaraokeResultCard(summary: summary) { session.completedSummary = nil }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                Text(String(localized: "karaoke_title"))
                    .tvFont(.eyebrow)
                    .foregroundStyle(TVColor.textFaint)
                Text(store.nowPlaying.title)
                    .tvFont(.pageTitle)
                    .foregroundStyle(TVColor.text)
                    .lineLimit(1)
                Text(store.nowPlaying.artist)
                    .tvFont(.body)
                    .foregroundStyle(TVColor.textMuted)
                    .lineLimit(1)
            }
            Spacer()
            if let score = session.runningScore {
                VStack(spacing: 2) {
                    Text("\(score)")
                        .tvFont(size: 72, weight: .heavy, design: .rounded, relativeTo: .largeTitle)
                        .monospacedDigit()
                        .foregroundStyle(TVColor.text)
                        .contentTransition(.numericText(value: Double(score)))
                    Text(String(localized: "karaoke_score"))
                        .tvFont(.caption)
                        .foregroundStyle(TVColor.textFaint)
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 12)
                .tvPanel(radius: 20)
                .animation(.spring(duration: 0.3), value: score)
            }
        }
    }

    @ViewBuilder
    private var lyrics: some View {
        if session.windows.isEmpty {
            Text(String(localized: "karaoke_no_lyrics"))
                .tvFont(.sectionTitle)
                .foregroundStyle(TVColor.textMuted)
                .multilineTextAlignment(.center)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !store.isPlaying)) { context in
                TVKaraokeLyrics(session: session, time: store.interpolatedTime(at: context.date))
            }
        }
    }

    private var controls: some View {
        HStack(alignment: .bottom, spacing: 28) {
            VStack(alignment: .leading, spacing: 14) {
                if let notice {
                    Text(notice)
                        .tvFont(.caption)
                        .foregroundStyle(TVColor.textMuted)
                        .lineLimit(2)
                }
                HStack(spacing: 20) {
                    stepButton(systemImage: "minus", enabled: session.isVocalReductionAvailable) {
                        session.vocalLevel = max(0, session.vocalLevel - 0.1)
                    }
                    VStack(spacing: 2) {
                        Text(String(localized: "karaoke_vocals"))
                            .tvFont(.caption)
                            .foregroundStyle(TVColor.textFaint)
                        Text(session.vocalLevel, format: .percent.precision(.fractionLength(0)))
                            .tvFont(.sectionTitle)
                            .monospacedDigit()
                            .foregroundStyle(TVColor.text)
                    }
                    .frame(minWidth: 140)
                    stepButton(systemImage: "plus", enabled: session.isVocalReductionAvailable) {
                        session.vocalLevel = min(1, session.vocalLevel + 0.1)
                    }
                    if session.hasDuetParts {
                        partButton(.all, "karaoke_part_all")
                        partButton(.primary, "karaoke_part_primary")
                        partButton(.secondary, "karaoke_part_secondary")
                    }
                    if session.runningScore != nil {
                        TVFocusButton(radius: 18, scale: 1.05, lift: 4, action: session.finishPerformance) { _ in
                            Label(String(localized: "karaoke_finish"), systemImage: "flag.checkered")
                                .tvFont(.button)
                                .padding(.horizontal, 28)
                                .frame(height: 72)
                        }
                    }
                }
            }
            Spacer()
            micPanel
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
        if !session.isVocalReductionAvailable {
            return String(localized: "karaoke_tv_unsupported")
        }
        if session.usesPhoneStem {
            return String(localized: "karaoke_tv_ai_active")
        }
        if let progress = session.phoneSeparationProgress {
            return String(format: String(localized: "karaoke_tv_ai_preparing_format"), Int((progress * 100).rounded()))
        }
        if session.isEffectivelyMono {
            return String(localized: "karaoke_mono_warning")
        }
        return nil
    }

    private func stepButton(systemImage: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        TVFocusButton(radius: 36, scale: 1.08, lift: 4, action: action) { _ in
            Image(systemName: systemImage)
                .font(.system(size: 30, weight: .bold))
                .frame(width: 72, height: 72)
        }
        .disabled(!enabled)
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
        let syllables = line.syllables ?? [LyricSyllable(text: line.text, start: window.start, end: window.end)]
        // Duets: the two singers in different colours, as on the phone.
        let sung = window.voice == .secondary
            ? Color(red: 1.0, green: 0.55, blue: 0.78)
            : Color(red: 0.42, green: 0.86, blue: 1.0)
        let pending = TVColor.text.opacity(0.55)
        var text = Text("")
        for syllable in syllables {
            let progress = syllable.end > syllable.start
                ? min(1, max(0, (time - syllable.start) / (syllable.end - syllable.start)))
                : (time >= syllable.start ? 1 : 0)
            let piece = Text(syllable.text).foregroundStyle(progress >= 1 ? sung : (progress > 0 ? sung.opacity(0.55 + 0.45 * progress) : pending))
            text = Text("\(text)\(piece)")
        }
        let mine = !session.hasDuetParts || session.part == .all
            || (session.part == .primary) == (window.voice == .primary)
        return VStack(spacing: 10) {
            if session.hasDuetParts, session.part != .all {
                Text(String(localized: mine ? "karaoke_you" : "karaoke_partner"))
                    .tvFont(.eyebrow)
                    .foregroundStyle(sung)
            }
            text
                .tvFont(size: 64, weight: .bold, relativeTo: .largeTitle)
                .multilineTextAlignment(.center)
                .lineLimit(3)
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
