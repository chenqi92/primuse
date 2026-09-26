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
            // @Observable 把 didSet 挪到底层存储上，这里回写走的是带观察的 setter，
            // 会再进一次 didSet；不比较就回写会无限递归把栈撑爆。
            let clamped = vocalLevel.isFinite ? min(1, max(0, vocalLevel)) : 0.1
            guard clamped == vocalLevel else {
                vocalLevel = clamped
                return
            }
            defaults.set(vocalLevel, forKey: "karaokeVocalLevel")
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
            let clamped = KaraokeKeyShiftPolicy.clamped(keyShift)
            guard clamped == keyShift else {
                keyShift = clamped
                return
            }
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
    let separation = KaraokeSeparationService.shared
    var localAIEnabled: Bool {
        didSet {
            guard localAIEnabled != oldValue else { return }
            defaults.set(localAIEnabled, forKey: "karaokeTVLocalAIEnabled")
            if localAIEnabled {
                separation.downloadModel()
                updateLocalSeparation()
            } else {
                cancelLocalSeparation()
                if !usesPhoneStem { removeStem() }
            }
        }
    }
    private(set) var currentSong: Song?
    private(set) var usesLocalStem = false
    private(set) var localStemLoadFailed = false

    private(set) var instrumentalCompanion: Song?
    private(set) var isPlayingInstrumental = false
    private(set) var lyricsBorrowedFromTitle: String?
    private(set) var usesInferredWordTiming = false
    private(set) var isVocalAssisting = false
    private(set) var isVocalAssistSuppressed = false
    var vocalAssistEnabled: Bool {
        didSet { defaults.set(vocalAssistEnabled, forKey: "karaokeVocalAssistEnabled") }
    }
    var practiceRate: Double = 1 {
        didSet {
            let clamped = practiceRate.isFinite ? min(1, max(0.5, practiceRate)) : 1
            guard practiceRate == clamped else { practiceRate = clamped; return }
            if isActive, practiceRate != oldValue {
                store.engine.setKaraokePracticeRate(practiceRate)
                resetPitchTracking()
            }
        }
    }
    private(set) var loop: KaraokePracticePolicy.Loop?
    var isPracticing: Bool { loop != nil || practiceRate < 1 }
    var canPractice: Bool { currentSong != nil && store.engine.supportsKaraokePractice }
    var isSwitchingTrack: Bool { store.engine.status == .loading && store.playbackIssue == nil }
    var canToggleBackingTrack: Bool {
        !isSwitchingTrack && (instrumentalCompanion != nil || (isPlayingInstrumental && pairedOriginal != nil))
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var pairedOriginal: Song?
    @ObservationIgnored private var carriedSongID: String?
    @ObservationIgnored private var companionTask: Task<Void, Never>?
    @ObservationIgnored private var wordTimingTask: Task<Void, Never>?
    @ObservationIgnored private var wordTimingGeneration = UUID()
    @ObservationIgnored private var vocalOnsets: [KaraokeOnset]?
    @ObservationIgnored private var vocalAssist = KaraokeVocalAssistPolicy()
    @ObservationIgnored private var lastMicReading: Date?
    @ObservationIgnored private var loopJumpIssuedAt: Date?
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
    @ObservationIgnored private var localStemTask: Task<Void, Never>?
    @ObservationIgnored private var stemGeneration = UUID()

    init(store: TVStore, defaults: UserDefaults = .standard) {
        self.store = store
        self.defaults = defaults
        vocalLevel = defaults.object(forKey: "karaokeVocalLevel") as? Double ?? 0.1
        localAIEnabled = defaults.bool(forKey: "karaokeTVLocalAIEnabled")
        vocalAssistEnabled = defaults.object(forKey: "karaokeVocalAssistEnabled") as? Bool ?? true
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
        store.engine.setKaraokePracticeRate(practiceRate)
        store.engine.karaokeLoopStartAtEnd = { [weak self] in
            guard let self, self.isActive, self.songID == self.store.currentSongID,
                  let loop = self.loop else { return nil }
            guard loop.end >= self.store.duration - KaraokePracticePolicy.leaveMargin else {
                self.loop = nil
                return nil
            }
            self.resetPitchTracking()
            return loop.start
        }
        micServer.start()
        if localAIEnabled { separation.downloadModel() }
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
        cancelLocalSeparation()
        companionTask?.cancel()
        cancelWordTiming()
        loop = nil
        practiceRate = 1
        store.engine.setKaraokePracticeRate(1)
        store.engine.karaokeLoopStartAtEnd = nil
        store.useKaraokeLyrics(from: nil)
        vocalAssist.reset()
        isVocalAssisting = false
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
        updateLocalSeparation()
        if !canPractice {
            if practiceRate != 1 { practiceRate = 1 }
            loop = nil
        }
        followLoop()
        applySettings()
        isEffectivelyMono = store.engine.karaokeProcessor.isEffectivelyMono
        tickCount &+= 1
        if isMicConnected, store.isPlaying, !isPlayingInstrumental {
            analyzeReferenceIfIdle()
            if tickCount % 40 == 0 {
                lagEstimator.update(reference: referenceTrack)
                lagIsCalibrated = lagEstimator.isCalibrated
            }
        }
        if tickCount % 20 == 0 {
            micServer.sendStatus(songTitle: store.nowPlaying.title, isPlaying: store.isPlaying, score: isPracticing ? nil : runningScore)
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
        if !vocalAssistApplies { vocalAssist.standDown() }
        let assistFactor = vocalAssist.advance(to: store.interpolatedTime())
        let assisting = vocalAssist.level > 0.5
        if isVocalAssisting != assisting { isVocalAssisting = assisting }
        if isVocalAssistSuppressed != vocalAssist.isSuppressed { isVocalAssistSuppressed = vocalAssist.isSuppressed }
        store.engine.karaokeProcessor.update(.init(
            isActive: isActive && isVocalReductionAvailable,
            reduction: isPlayingInstrumental ? 0 : Float((1 - vocalLevel) * assistFactor) * duetFactor,
            capturesVocal: isActive && isMicConnected && !isPlayingInstrumental,
            bypassesVocalReduction: isPlayingInstrumental,
            stemAddress: stem.map { UInt(bitPattern: $0.samples) } ?? 0,
            stemFrames: stem?.frames ?? 0,
            stemTimeOffset: store.engine.playbackPhysicalStart,
            keyShift: keyShift
        ))
    }

    private func songOrLyricsChanged() {
        let songChanged = songID != store.currentSongID
        let carrying = songChanged && carriedSongID == store.currentSongID && carriedSongID != nil
        if songChanged {
            if !carrying { finishPerformance() }
            cancelLocalSeparation()
            companionTask?.cancel()
            if !carrying {
                cancelWordTiming()
                vocalOnsets = nil
                pairedOriginal = nil
                instrumentalCompanion = nil
                lyricsBorrowedFromTitle = nil
                loop = nil
                loopJumpIssuedAt = nil
                store.useKaraokeLyrics(from: nil)
            }
            songID = store.currentSongID
            currentSong = songID.flatMap { store.library.song(id: $0) }
            removeStem()
            phoneSeparationProgress = nil
            carriedSongID = nil
            isPlayingInstrumental = currentSong.map {
                KaraokeCompanionPolicy.isInstrumental(Self.companionCandidate($0))
            } ?? false
            micServer.sendNowPlaying(songID: isPlayingInstrumental ? nil : songID)
            resetPitchTracking()
            if !canPractice { practiceRate = 1 }
            if !carrying, let currentSong { findCompanion(for: currentSong) }
        }
        lyricsRevision = store.lyricsRevision
        let loaded = store.lyrics.map(Self.lyricLine)
        // Switching files clears the player's lyrics before the original is loaded.
        if carrying || (pairedOriginal != nil && loaded.isEmpty && !lyrics.isEmpty) { return }
        guard songChanged || loaded != lyrics else { return }
        lyrics = loaded
        windows = KaraokeLineWindowPolicy.windows(in: lyrics)
        buildStageLines()
        hasDuetParts = KaraokeDuetGatePolicy.hasDuetParts(lyrics)
        if songChanged || !hasDuetParts { part = .all }
        loop = nil
        scorer = KaraokeScorer(lines: lyrics, part: hasDuetParts ? part : .all)
        runningScore = nil
    }

    private func resetPitchTracking() {
        referenceTrack.removeAll()
        lagEstimator.reset()
        lagIsCalibrated = false
        pitchHistory = []
        lastMicReading = nil
        vocalAssist.reset()
    }

    nonisolated static func companionCandidate(_ song: Song) -> KaraokeCompanionCandidate {
        KaraokeCompanionCandidate(id: song.id, title: song.title, artistName: song.artistName,
                                  albumTitle: song.albumTitle, duration: song.duration,
                                  filePath: song.filePath, sourceID: song.sourceID)
    }

    private func findCompanion(for song: Song) {
        let songs = store.library.visibleSongs
        let target = Self.companionCandidate(song)
        let backing = isPlayingInstrumental
        companionTask = Task { @MainActor [weak self] in
            let matchID = await Task.detached(priority: .utility) {
                let candidates = songs.map(Self.companionCandidate)
                return (backing ? KaraokeCompanionPolicy.original(for: target, in: candidates)
                        : KaraokeCompanionPolicy.instrumental(for: target, in: candidates))?.id
            }.value
            guard !Task.isCancelled, let self, self.isActive, self.songID == song.id else { return }
            let match = matchID.flatMap { self.store.library.song(id: $0) }
            if backing, let original = match {
                self.pairedOriginal = original
                self.instrumentalCompanion = song
                self.lyricsBorrowedFromTitle = original.title
                self.store.useKaraokeLyrics(from: original)
            } else {
                self.instrumentalCompanion = match
            }
        }
    }

    func toggleBackingTrack() {
        guard canToggleBackingTrack, let currentSong else { return }
        let target = isPlayingInstrumental ? pairedOriginal : instrumentalCompanion
        guard let target else { return }
        if !isPlayingInstrumental { pairedOriginal = currentSong }
        carriedSongID = target.id
        guard store.switchKaraokeTrack(to: target.id) else { carriedSongID = nil; return }
        songOrLyricsChanged()
        lyricsBorrowedFromTitle = isPlayingInstrumental ? pairedOriginal?.title : nil
        store.useKaraokeLyrics(from: pairedOriginal)
        applySettings()
    }

    private func buildStageLines() {
        let byIndex = Dictionary(uniqueKeysWithValues: windows.map { ($0.lineIndex, $0) })
        var inferred = false
        stageLines = lyrics.enumerated().map { index, line in
            guard let window = byIndex[index] else { return line }
            if let vocalOnsets, let timed = KaraokeWordTimingPolicy.timedLine(line, window: window, onsets: vocalOnsets) {
                inferred = true
                return timed
            }
            return KaraokeSweepPolicy.sweepLine(line, window: window)
        }
        usesInferredWordTiming = inferred
    }

    private func cancelWordTiming() {
        wordTimingGeneration = UUID()
        wordTimingTask?.cancel()
        wordTimingTask = nil
    }

    private func inferWordTiming(from track: TVKaraokeStemTrack) {
        cancelWordTiming()
        let generation = wordTimingGeneration
        wordTimingTask = Task { @MainActor [weak self] in
            let onsets = await Task.detached(priority: .utility) {
                track.onsets()
            }.value
            guard !Task.isCancelled, let self, self.isActive,
                  self.wordTimingGeneration == generation else { return }
            self.wordTimingTask = nil
            self.vocalOnsets = onsets
            self.buildStageLines()
        }
    }

    private var vocalAssistApplies: Bool {
        vocalAssistEnabled && isMicConnected && isVocalReductionAvailable
            && !isPlayingInstrumental && store.isPlaying
            && lastMicReading.map { Date().timeIntervalSince($0) < 0.75 } == true
    }

    func toggleLoop() {
        if loop != nil { loop = nil; return }
        guard canPractice else { return }
        loop = KaraokePracticePolicy.loop(windows: windows, at: store.interpolatedTime())
        loopJumpIssuedAt = nil
    }

    func extendLoop() {
        guard let loop else { return }
        if let extended = KaraokePracticePolicy.extended(loop, windows: windows) { self.loop = extended }
    }

    var canExtendLoop: Bool {
        guard let loop else { return false }
        return loop.lastWindow + 1 < windows.count
    }

    private func followLoop() {
        guard let loop, store.isPlaying else { return }
        let time = store.interpolatedTime()
        if let issued = loopJumpIssuedAt {
            if time < loop.end || Date().timeIntervalSince(issued) >= 2 { loopJumpIssuedAt = nil }
            return
        }
        switch KaraokePracticePolicy.action(for: loop, at: time) {
        case .none: break
        case .jumpBack:
            loopJumpIssuedAt = Date()
            resetPitchTracking()
            store.engine.seek(to: loop.start)
        case .leave: self.loop = nil
        }
    }

    // MARK: AI stem from the phone

    private func receiveStem(songID stemSongID: String, data: Data) {
        guard isActive, !isPlayingInstrumental, stemSongID == songID else { return }
        let targetRate = store.engine.karaokeProcessor.sampleRate
        let generation = stemGeneration
        Task { @MainActor [weak self] in
            let track = await Task.detached(priority: .userInitiated) { () -> TVKaraokeStemTrack? in
                guard let stem = KaraokeStemFile.decode(data) else { return nil }
                if abs(stem.header.sampleRate - targetRate) < 0.5 {
                    return TVKaraokeStemTrack(songID: stemSongID, left: stem.left, right: stem.right, sampleRate: targetRate)
                }
                guard let resampled = Self.resample(left: stem.left, right: stem.right, from: stem.header.sampleRate, to: targetRate) else { return nil }
                return TVKaraokeStemTrack(songID: stemSongID, left: resampled.left, right: resampled.right, sampleRate: targetRate)
            }.value
            guard let self, self.isActive, generation == self.stemGeneration,
                  let track, track.songID == self.songID,
                  abs(track.sampleRate - self.store.engine.karaokeProcessor.sampleRate) < 0.5 else { return }
            self.cancelLocalSeparation()
            self.removeStem()
            self.stemTrack = track
            self.usesPhoneStem = true
            self.inferWordTiming(from: track)
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
        usesLocalStem = false
        applySettings()
        retiredStems.append(track)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            self?.retiredStems.removeAll { $0 === track }
        }
    }

    // MARK: AI on this Apple TV

    func retryLocalSeparation() {
        if localStemLoadFailed, let song = currentSong { separation.discardStem(for: song) }
        localStemLoadFailed = false
        if separation.modelState == .failed {
            separation.downloadModel()
        } else if let song = currentSong, separation.state(for: song) == .failed {
            separation.prepare(song) { [store] in try await store.karaokeAudioFile(for: song) }
        }
        updateLocalSeparation()
    }

    private func cancelLocalSeparation() {
        stemGeneration = UUID()
        localStemTask?.cancel()
        localStemTask = nil
        localStemLoadFailed = false
        if let songID { separation.cancel(songID) }
    }

    private func updateLocalSeparation() {
        guard isActive, localAIEnabled, !isPlayingInstrumental, isVocalReductionAvailable, !usesPhoneStem,
              let song = currentSong, separation.modelState == .ready else { return }
        if let track = stemTrack,
           abs(track.sampleRate - store.engine.karaokeProcessor.sampleRate) >= 0.5 {
            cancelLocalSeparation()
            removeStem()
        }
        switch separation.state(for: song) {
        case .idle:
            separation.prepare(song) { [store] in try await store.karaokeAudioFile(for: song) }
        case .ready:
            guard !usesLocalStem, localStemTask == nil, !localStemLoadFailed else { return }
            let generation = stemGeneration
            let rate = store.engine.karaokeProcessor.sampleRate
            localStemTask = Task { @MainActor [weak self, separation] in
                let samples = await separation.loadStemSamples(for: song, graphSampleRate: rate)
                let track = await Task.detached(priority: .userInitiated) {
                    samples.map { TVKaraokeStemTrack(songID: song.id, left: $0.left, right: $0.right, sampleRate: rate) }
                }.value
                guard !Task.isCancelled, let self, self.isActive, self.localAIEnabled,
                      self.stemGeneration == generation, self.songID == song.id, !self.usesPhoneStem else { return }
                self.localStemTask = nil
                guard abs(rate - self.store.engine.karaokeProcessor.sampleRate) < 0.5 else { return }
                guard let track else {
                    self.localStemLoadFailed = true
                    return
                }
                self.removeStem()
                self.stemTrack = track
                self.usesLocalStem = true
                self.inferWordTiming(from: track)
                self.applySettings()
            }
        case .separating, .unsupported, .failed:
            break
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
        let expectedSongID = songID
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
            guard self.isActive, self.songID == expectedSongID, self.store.isPlaying else { return }
            // The vocal is taken before the key change; the singer follows
            // the shifted key.
            let shift = Double(self.isVocalReductionAvailable ? self.keyShift : 0)
            self.referenceTrack.append(time: time, midiNote: note.map { $0 + shift })
        }
    }

    private func receive(sung note: Double?) {
        guard isActive, store.isPlaying else { return }
        lastMicReading = Date()
        let now = store.interpolatedTime()
        lagEstimator.record(time: now, sung: note)
        let sungTime = now - lagEstimator.lag
        let reference = referenceTrack.note(at: sungTime)
        if !isPracticing && !isPlayingInstrumental {
            scorer.record(time: sungTime, reference: reference, sung: note)
        }
        if vocalAssistApplies {
            vocalAssist.observe(time: sungTime,
                                inOwnLine: KaraokeVocalAssistPolicy.isOwnLine(windows: windows, part: part, at: sungTime),
                                sung: note, reference: reference)
        }
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
