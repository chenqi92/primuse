#if os(tvOS)
import AVFoundation
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

    /// Which singer the user takes when the lyrics mark a duet.
    var part: KaraokePart = .all {
        didSet {
            guard part != oldValue else { return }
            scorer = KaraokeScorer(lines: lyrics, part: hasDuetParts ? part : .all)
            runningScore = nil
        }
    }
    private(set) var hasDuetParts = false
    /// Key change in semitones for the karaoke track.
    var keyShift = 0 {
        didSet {
            keyShift = KaraokeKeyShiftPolicy.clamped(keyShift)
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
    /// The AI vocal the phone separated for the current song is in use.
    private(set) var usesPhoneStem = false
    /// The phone is separating the current song; 0...1.
    private(set) var phoneSeparationProgress: Double?

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
    @ObservationIgnored private var stemTrack: TVKaraokeStemTrack?
    @ObservationIgnored private var retiredStems: [TVKaraokeStemTrack] = []

    init(store: TVStore) {
        self.store = store
        vocalLevel = UserDefaults.standard.object(forKey: "karaokeVocalLevel") as? Double ?? 0.1
        micServer.onReading = { [weak self] note in self?.receive(sung: note) }
        micServer.onStem = { [weak self] songID, data in self?.receiveStem(songID: songID, data: data) }
        micServer.onSeparationProgress = { [weak self] songID, fraction in
            guard let self, songID == self.songID, !self.usesPhoneStem else { return }
            self.phoneSeparationProgress = fraction
        }
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
        removeStem()
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
        let stem = stemTrack.flatMap { $0.songID == songID ? $0 : nil }
        // In a duet the partner's rows keep the original vocal.
        let duetFactor = KaraokeDuetGatePolicy.reductionFactor(
            windows: windows,
            part: hasDuetParts ? part : .all,
            at: store.interpolatedTime()
        )
        store.engine.karaokeProcessor.update(.init(
            isActive: isActive && isVocalReductionAvailable,
            reduction: Float(1 - vocalLevel) * duetFactor,
            capturesVocal: isActive && isMicConnected,
            stemAddress: stem.map { UInt(bitPattern: $0.samples) } ?? 0,
            stemFrames: stem?.frames ?? 0,
            stemTimeOffset: store.engine.playbackPhysicalStart,
            keyShift: keyShift
        ))
    }

    private func songOrLyricsChanged() {
        let songChanged = songID != store.currentSongID
        if songID != nil, songChanged {
            finishPerformance()
        }
        songID = store.currentSongID
        if songChanged {
            removeStem()
            phoneSeparationProgress = nil
            micServer.sendNowPlaying(songID: songID)
        }
        lyricsRevision = store.lyricsRevision
        lyrics = store.lyrics.map(Self.lyricLine)
        windows = KaraokeLineWindowPolicy.windows(in: lyrics)
        let byIndex = Dictionary(uniqueKeysWithValues: windows.map { ($0.lineIndex, $0) })
        stageLines = lyrics.enumerated().map { index, line in
            byIndex[index].map { KaraokeSweepPolicy.sweepLine(line, window: $0) } ?? line
        }
        hasDuetParts = KaraokeDuetGatePolicy.hasDuetParts(lyrics)
        if songChanged || !hasDuetParts { part = .all }
        scorer = KaraokeScorer(lines: lyrics, part: hasDuetParts ? part : .all)
        referenceTrack.removeAll()
        if songChanged {
            // Readings from the last song would pull the new estimate.
            lagEstimator.reset()
            lagIsCalibrated = false
        }
        pitchHistory = []
        runningScore = nil
    }

    // MARK: AI stem from the phone

    private func receiveStem(songID stemSongID: String, data: Data) {
        guard isActive, stemSongID == songID else { return }
        let targetRate = store.engine.karaokeProcessor.sampleRate
        Task { @MainActor [weak self] in
            let track = await Task.detached(priority: .userInitiated) { () -> TVKaraokeStemTrack? in
                guard let stem = KaraokeStemFile.decode(data) else { return nil }
                if abs(stem.header.sampleRate - targetRate) < 0.5 {
                    return TVKaraokeStemTrack(songID: stemSongID, left: stem.left, right: stem.right, sampleRate: targetRate)
                }
                guard let resampled = Self.resample(left: stem.left, right: stem.right, from: stem.header.sampleRate, to: targetRate) else { return nil }
                return TVKaraokeStemTrack(songID: stemSongID, left: resampled.left, right: resampled.right, sampleRate: targetRate)
            }.value
            guard let self, self.isActive, let track, track.songID == self.songID else { return }
            self.removeStem()
            self.stemTrack = track
            self.usesPhoneStem = true
            self.phoneSeparationProgress = nil
            self.applySettings()
        }
    }

    /// Takes the stem out of the tap; the samples stay alive a moment in
    /// case a render cycle already read the old address.
    private func removeStem() {
        guard let track = stemTrack else { return }
        stemTrack = nil
        usesPhoneStem = false
        applySettings()
        retiredStems.append(track)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            self?.retiredStems.removeAll { $0 === track }
        }
    }

    private nonisolated static func resample(
        left: [Float],
        right: [Float],
        from sourceRate: Double,
        to targetRate: Double
    ) -> (left: [Float], right: [Float])? {
        guard let sourceFormat = AVAudioFormat(standardFormatWithSampleRate: sourceRate, channels: 2),
              let targetFormat = AVAudioFormat(standardFormatWithSampleRate: targetRate, channels: 2),
              let converter = AVAudioConverter(from: sourceFormat, to: targetFormat),
              let input = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(left.count)),
              let channels = input.floatChannelData else { return nil }
        input.frameLength = AVAudioFrameCount(left.count)
        left.withUnsafeBufferPointer { channels[0].update(from: $0.baseAddress!, count: left.count) }
        right.withUnsafeBufferPointer { channels[1].update(from: $0.baseAddress!, count: right.count) }
        let capacity = AVAudioFrameCount(Double(left.count) * targetRate / sourceRate) + 4_096
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return nil }
        let pending = TVKaraokeOneShotBuffer(input)
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            guard let buffer = pending.take() else {
                inputStatus.pointee = .endOfStream
                return nil
            }
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, let out = output.floatChannelData else { return nil }
        let count = Int(output.frameLength)
        return (Array(UnsafeBufferPointer(start: out[0], count: count)), Array(UnsafeBufferPointer(start: out[1], count: count)))
    }

    static func lyricLine(_ line: TVLyricLine) -> LyricLine {
        LyricLine(
            id: line.id,
            timestamp: line.time,
            text: line.text,
            isSynchronized: line.isSynchronized,
            syllables: line.syllables.isEmpty ? nil : line.syllables.map {
                LyricSyllable(text: $0.w, start: $0.start, end: $0.end, endTiming: $0.endTiming)
            },
            voice: line.voice
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
            // The vocal is taken before the key change; the singer follows
            // the shifted key.
            let shift = Double(self.isVocalReductionAvailable ? self.keyShift : 0)
            self.referenceTrack.append(time: time, midiNote: note.map { $0 + shift })
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
/// Hands one buffer to an AVAudioConverter input block, then ends.
private final class TVKaraokeOneShotBuffer: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?
    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
    func take() -> AVAudioPCMBuffer? {
        defer { buffer = nil }
        return buffer
    }
}
#endif
