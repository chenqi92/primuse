#if os(tvOS)
import Foundation
import Observation
import PrimuseKit

/// Karaoke on the TV: vocal reduction in the playback tap, big lyrics, and
/// scoring from an iPhone that joins as the microphone. Lives as long as the
/// karaoke stage is on screen.
@MainActor
@Observable
final class TVKaraokeSession {
    struct PitchPoint: Equatable {
        var time: TimeInterval
        var reference: Double?
        var sung: Double?
    }

    static let pitchHistoryDuration: TimeInterval = 5

    let store: TVStore
    let micServer = TVKaraokeMicServer()

    /// 1 keeps the original vocal, 0 removes it. Shared with the phone app's
    /// preference of the same name.
    var vocalLevel: Double {
        didSet {
            vocalLevel = min(1, max(0, vocalLevel))
            UserDefaults.standard.set(vocalLevel, forKey: "karaokeVocalLevel")
            applySettings()
        }
    }

    private(set) var isActive = false
    private(set) var windows: [KaraokeLineWindow] = []
    private(set) var stageLines: [LyricLine] = []
    private(set) var isEffectivelyMono = false
    private(set) var pitchHistory: [PitchPoint] = []
    private(set) var runningScore: Int?
    private(set) var lagIsCalibrated = false
    var completedSummary: KaraokeScoreSummary?

    @ObservationIgnored private var songID: String?
    @ObservationIgnored private var lyricsRevision = -1
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored private var scorer = KaraokeScorer(lines: [])
    @ObservationIgnored private var lyrics: [LyricLine] = []
    @ObservationIgnored private var referenceTrack = KaraokePitchTrack(capacity: 800)
    @ObservationIgnored private var lagEstimator = KaraokeLagEstimator()
    @ObservationIgnored private var detector: KaraokePitchDetector?
    @ObservationIgnored private var isAnalyzing = false
    @ObservationIgnored private var tickCount = 0

    init(store: TVStore) {
        self.store = store
        vocalLevel = UserDefaults.standard.object(forKey: "karaokeVocalLevel") as? Double ?? 0.1
        micServer.onReading = { [weak self] note in self?.receive(sung: note) }
    }

    var isVocalReductionAvailable: Bool { store.engine.isKaraokeTapInstalled }

    var isMicConnected: Bool {
        if case .connected = micServer.state { return true }
        return false
    }

    func start() {
        guard !isActive else { return }
        isActive = true
        store.engine.setKaraokeTapEnabled(true)
        micServer.start()
        tick()
        tickTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard let self, self.isActive else { return }
                self.tick()
            }
        }
    }

    func stop() {
        guard isActive else { return }
        isActive = false
        tickTask?.cancel()
        tickTask = nil
        micServer.stop()
        store.engine.karaokeProcessor.update(.init())
        store.engine.setKaraokeTapEnabled(false)
    }

    /// Shows the result card for what has been sung so far.
    func finishPerformance() {
        let summary = scorer.summary()
        if !summary.isEmpty { completedSummary = summary }
        scorer.reset()
        runningScore = nil
    }

    // MARK: Ticking

    private func tick() {
        if store.currentSongID != songID || store.lyricsRevision != lyricsRevision {
            songOrLyricsChanged()
        }
        applySettings()
        isEffectivelyMono = store.engine.karaokeProcessor.isEffectivelyMono
        tickCount &+= 1
        if isMicConnected, store.isPlaying {
            analyzeReferenceIfIdle()
            if tickCount % 40 == 0 {
                lagEstimator.update(reference: referenceTrack)
                lagIsCalibrated = lagEstimator.isCalibrated
            }
        }
        if tickCount % 20 == 0 {
            micServer.sendStatus(songTitle: store.nowPlaying.title, isPlaying: store.isPlaying, score: runningScore)
        }
    }

    private func applySettings() {
        store.engine.karaokeProcessor.update(.init(
            isActive: isActive && isVocalReductionAvailable,
            reduction: Float(1 - vocalLevel),
            capturesVocal: isActive && isMicConnected
        ))
    }

    private func songOrLyricsChanged() {
        if songID != nil, songID != store.currentSongID {
            finishPerformance()
        }
        songID = store.currentSongID
        lyricsRevision = store.lyricsRevision
        lyrics = store.lyrics.map(Self.lyricLine)
        windows = KaraokeLineWindowPolicy.windows(in: lyrics)
        let byIndex = Dictionary(uniqueKeysWithValues: windows.map { ($0.lineIndex, $0) })
        stageLines = lyrics.enumerated().map { index, line in
            byIndex[index].map { KaraokeSweepPolicy.sweepLine(line, window: $0) } ?? line
        }
        scorer = KaraokeScorer(lines: lyrics)
        referenceTrack.removeAll()
        pitchHistory = []
        runningScore = nil
    }

    static func lyricLine(_ line: TVLyricLine) -> LyricLine {
        LyricLine(
            id: line.id,
            timestamp: line.time,
            text: line.text,
            isSynchronized: line.isSynchronized,
            syllables: line.syllables.isEmpty ? nil : line.syllables.map {
                LyricSyllable(text: $0.w, start: $0.start, end: $0.end, endTiming: $0.endTiming)
            }
        )
    }

    // MARK: Scoring

    /// The removed vocal's pitch, as the reference melody.
    private func analyzeReferenceIfIdle() {
        guard !isAnalyzing else { return }
        let processor = store.engine.karaokeProcessor
        let rate = processor.sampleRate / 2
        if detector?.sampleRate != rate {
            detector = KaraokePitchDetector(sampleRate: rate, windowSize: 2_048)
        }
        guard let detector else { return }
        let time = store.interpolatedTime()
        isAnalyzing = true
        Task { @MainActor [weak self] in
            let note = await Task.detached(priority: .utility) { () -> Double? in
                guard let raw = processor.vocalRing.readLatest(4_096) else { return nil }
                // Pair averaging: half the rate, a crude anti-alias filter.
                let window = (0..<2_048).map { (raw[2 * $0] + raw[2 * $0 + 1]) * 0.5 }
                guard let estimate = detector.detect(window), estimate.confidence >= 0.8 else { return nil }
                return estimate.midiNote
            }.value
            guard let self else { return }
            self.isAnalyzing = false
            self.referenceTrack.append(time: time, midiNote: note)
        }
    }

    private func receive(sung note: Double?) {
        guard isActive, store.isPlaying else { return }
        let now = store.interpolatedTime()
        lagEstimator.record(time: now, sung: note)
        let sungTime = now - lagEstimator.lag
        let reference = referenceTrack.note(at: sungTime)
        scorer.record(time: sungTime, reference: reference, sung: note)
        pitchHistory.append(PitchPoint(time: sungTime, reference: reference, sung: note))
        let cutoff = sungTime - Self.pitchHistoryDuration
        if let first = pitchHistory.firstIndex(where: { $0.time >= cutoff }), first > 0 {
            pitchHistory.removeFirst(first)
        }
        let summary = scorer.summary()
        runningScore = summary.isEmpty ? nil : summary.totalScore
    }
}
#endif
