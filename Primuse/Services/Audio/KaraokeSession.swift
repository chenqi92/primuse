import AVFoundation
import Foundation
import Observation
import PrimuseKit

/// Reads the vocal-estimate and microphone rings off the main actor and
/// turns their newest windows into MIDI notes.
actor KaraokePitchAnalyzer {
    struct Reading: Sendable {
        var reference: Double?
        var sung: Double?
    }

    /// Voice needs nothing above ~1.1 kHz, so windows are halved in rate
    /// before YIN: a quarter of the work for the same resolution.
    private static let decimation = 2
    private static let analysisWindow = 2_048
    /// The vocal estimate carries other centred instruments; only confident
    /// readings count as melody.
    private static let referenceConfidence = 0.8
    private static let sungConfidence = 0.6

    private let vocalRing: KaraokeSampleRing
    private let microphoneRing: KaraokeSampleRing
    private var vocalDetector: KaraokePitchDetector?
    private var microphoneDetector: KaraokePitchDetector?
    private var raw = [Float](repeating: 0, count: analysisWindow * decimation)
    private var window = [Float](repeating: 0, count: analysisWindow)

    init(vocalRing: KaraokeSampleRing, microphoneRing: KaraokeSampleRing) {
        self.vocalRing = vocalRing
        self.microphoneRing = microphoneRing
    }

    func analyze(vocalSampleRate: Double, microphoneSampleRate: Double) -> Reading {
        vocalDetector = detector(vocalDetector, rate: vocalSampleRate)
        microphoneDetector = detector(microphoneDetector, rate: microphoneSampleRate)
        var reading = Reading()
        if let estimate = latestPitch(from: vocalRing, detector: vocalDetector),
           estimate.confidence >= Self.referenceConfidence {
            reading.reference = estimate.midiNote
        }
        if let estimate = latestPitch(from: microphoneRing, detector: microphoneDetector),
           estimate.confidence >= Self.sungConfidence {
            reading.sung = estimate.midiNote
        }
        return reading
    }

    private func detector(_ current: KaraokePitchDetector?, rate: Double) -> KaraokePitchDetector? {
        let decimatedRate = rate / Double(Self.decimation)
        guard rate > 0 else { return nil }
        if let current, current.sampleRate == decimatedRate { return current }
        return KaraokePitchDetector(sampleRate: decimatedRate, windowSize: Self.analysisWindow)
    }

    private func latestPitch(
        from ring: KaraokeSampleRing,
        detector: KaraokePitchDetector?
    ) -> KaraokePitchEstimate? {
        guard let detector else { return nil }
        let count = Self.analysisWindow * Self.decimation
        let fresh = raw.withUnsafeMutableBufferPointer { ring.readLatest(count, into: $0.baseAddress!) }
        guard fresh else { return nil }
        for index in 0..<Self.analysisWindow {
            // Pair averaging doubles as a crude anti-alias filter.
            window[index] = (raw[index * 2] + raw[index * 2 + 1]) * 0.5
        }
        return window.withUnsafeBufferPointer { detector.detect($0) }
    }
}

/// A finished song sung with the microphone on.
struct KaraokePerformance: Identifiable, Sendable {
    let id = UUID()
    let songTitle: String
    let artistName: String
    let summary: KaraokeScoreSummary
    let bestLineText: String?
    var recordingURL: URL?
}

/// Everything karaoke mode does while the karaoke stage is open. Closing
/// the stage ends the session and puts playback back exactly as it was.
@MainActor
@Observable
final class KaraokeSession {
    enum MicrophoneState: Equatable {
        case off
        case starting
        case on
        case denied
        case unavailable
    }

    struct PitchPoint: Equatable {
        var time: TimeInterval
        var reference: Double?
        var sung: Double?
    }

    static let vocalLevelKey = "karaokeVocalLevel"
    static let aiSeparationKey = "karaokeAISeparationEnabled"
    static let vocalAssistKey = "karaokeVocalAssistEnabled"
    static let defaultVocalLevel = 0.1
    /// Seconds of pitch history the stage draws.
    static let pitchHistoryDuration: TimeInterval = 5

    let player: AudioPlayerService
    @ObservationIgnored private let engine: AudioEngine
    @ObservationIgnored private let defaults: UserDefaults

    /// 1 keeps the original vocal, 0 removes it.
    var vocalLevel: Double {
        didSet {
            // @Observable 把 didSet 挪到底层存储上，这里回写走的是带观察的 setter，
            // 会再进一次 didSet；不比较就回写会无限递归把栈撑爆。
            let clamped = vocalLevel.isFinite ? min(1, max(0, vocalLevel)) : Self.defaultVocalLevel
            guard clamped == vocalLevel else {
                vocalLevel = clamped
                return
            }
            defaults.set(vocalLevel, forKey: Self.vocalLevelKey)
            applyRenderSettings()
        }
    }

    var keyShift = 0 {
        didSet {
            let clamped = KaraokeKeyShiftPolicy.clamped(keyShift)
            guard clamped == keyShift else {
                keyShift = clamped
                return
            }
            applyRenderSettings()
        }
    }

    var part: KaraokePart = .all {
        didSet {
            guard part != oldValue else { return }
            rebuildScorer()
        }
    }

    private(set) var isActive = false
    private(set) var availability: KaraokeAvailability = .noSong
    private(set) var isEffectivelyMono = false
    private(set) var songID: String?
    private(set) var stageLines: [LyricLine] = []
    private(set) var windows: [KaraokeLineWindow] = []
    private(set) var hasDuetParts = false
    private(set) var isLoadingLyrics = false
    /// The library's instrumental version of the playing song, when one exists.
    private(set) var instrumentalCompanion: Song?
    /// What is playing is an instrumental (a paired companion or a backing
    /// track played directly): nothing to reduce, lyrics come from the original.
    private(set) var isPlayingInstrumental = false
    /// Title of the sung original the lyrics were borrowed from.
    private(set) var lyricsBorrowedFromTitle: String?
    private(set) var isSwitchingTrack = false

    /// Use the AI-separated vocal when this device has the model.
    var aiSeparationEnabled: Bool {
        didSet {
            defaults.set(aiSeparationEnabled, forKey: Self.aiSeparationKey)
            if !aiSeparationEnabled { removeStem() }
        }
    }
    let separation = KaraokeSeparationService.shared

    /// Practice speed; the key stays. Not kept once the stage closes.
    var practiceRate: Double = 1 {
        didSet {
            guard practiceRate != oldValue else { return }
            applyPracticeRate()
            if isPracticing, isRecording { finishRecording() }
        }
    }
    /// The lines being played over and over.
    private(set) var loop: KaraokePracticePolicy.Loop?
    /// Slowed down or looping: nothing is scored or recorded meanwhile.
    var isPracticing: Bool { loop != nil || practiceRate < 1 }

    /// Brings the original vocal back while the singer is silent in their line.
    var vocalAssistEnabled: Bool {
        didSet {
            defaults.set(vocalAssistEnabled, forKey: Self.vocalAssistKey)
            applyRenderSettings()
        }
    }
    /// The original vocal is helping out right now.
    private(set) var isVocalAssisting = false
    /// Assist gave up for this song: the microphone hears the playback.
    private(set) var isVocalAssistSuppressed = false
    /// The AI stem for this song is loaded into the playback graph.
    private(set) var isStemActive = false
    /// The stem is aligned with what is playing and being subtracted.
    private(set) var isStemLocked = false
    /// Line-level lyrics are being swept word by word on the sung vocal.
    private(set) var usesInferredWordTiming = false

    private(set) var microphoneState: MicrophoneState = .off
    private(set) var canMonitor = false
    var isMonitoring = false {
        didSet { microphone.monitorVolume = isMonitoring && canMonitor ? 1 : 0 }
    }
    private(set) var pitchHistory: [PitchPoint] = []
    private(set) var liveLineScore: KaraokeLineScore?
    private(set) var runningScore: Int?
    var completedPerformance: KaraokePerformance?

    private(set) var isRecording = false
    private(set) var isMixingRecording = false
    private(set) var lastRecordingURL: URL?
    private(set) var recordingFailed = false

    @ObservationIgnored private let microphone: KaraokeMicrophone
    @ObservationIgnored private let analyzer: KaraokePitchAnalyzer
    @ObservationIgnored private var scorer = KaraokeScorer(lines: [])
    @ObservationIgnored private var referenceTrack = KaraokePitchTrack()
    @ObservationIgnored private var lyrics: [LyricLine] = []
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored private var lyricsTask: Task<Void, Never>?
    @ObservationIgnored private var isAnalyzing = false
    @ObservationIgnored private var songTitle = ""
    @ObservationIgnored private var artistName = ""
    @ObservationIgnored private var accompanimentWriter: KaraokeTakeWriter?
    @ObservationIgnored private var accompanimentTapNode: AVAudioNode?
    @ObservationIgnored private var companionTask: Task<Void, Never>?
    /// Set while switching between a song and its instrumental: the change to
    /// this id keeps the lyrics, timing and score of the performance.
    @ObservationIgnored private var carriedSongID: String?
    @ObservationIgnored private var pairedOriginal: Song?
    @ObservationIgnored private var stemSongID: String?
    @ObservationIgnored private var stemTrack: KaraokeStemTrack?
    @ObservationIgnored private var retiredStems: [KaraokeStemTrack] = []
    @ObservationIgnored private var stemLoadTask: Task<Void, Never>?
    @ObservationIgnored private var lockPolicy = KaraokeStemLockPolicy()
    @ObservationIgnored private var lockPolicyEpoch = -1
    @ObservationIgnored private var isAligning = false
    @ObservationIgnored private var tickCount = 0
    @ObservationIgnored private var pausedRecordingTicks = 0
    /// Ticks (50 ms) of continuous pause before a take is closed, so a
    /// resume that is still settling does not end it.
    private static let recordingPauseTicks = 40
    @ObservationIgnored private var wordTimingSongID: String?
    @ObservationIgnored private var vocalAssist = KaraokeVocalAssistPolicy()
    /// A jump back to the loop start is on its way; the playhead still
    /// reads past the end until it lands.
    @ObservationIgnored private var loopJumpIssuedAt: Date?
    /// Headphones: the returning original cannot reach the microphone.
    @ObservationIgnored private var assistRouteAllows = false
    @ObservationIgnored private var wordTimingTask: Task<Void, Never>?

    init(player: AudioPlayerService, defaults: UserDefaults = .standard) {
        self.player = player
        engine = player.audioEngine
        self.defaults = defaults
        vocalLevel = defaults.object(forKey: Self.vocalLevelKey) as? Double ?? Self.defaultVocalLevel
        aiSeparationEnabled = defaults.object(forKey: Self.aiSeparationKey) as? Bool ?? true
        vocalAssistEnabled = defaults.object(forKey: Self.vocalAssistKey) as? Bool ?? true
        let microphone = KaraokeMicrophone()
        self.microphone = microphone
        analyzer = KaraokePitchAnalyzer(
            vocalRing: player.audioEngine.karaokeControl.vocalRing,
            microphoneRing: microphone.ring
        )
    }

    // MARK: - Lifecycle

    func start() {
        guard !isActive else { return }
        isActive = true
        player.setKaraokeSessionActive(true)
        #if DEBUG
        startDebugPractice()
        #endif
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
        lyricsTask?.cancel()
        lyricsTask = nil
        companionTask?.cancel()
        companionTask = nil
        if isRecording { finishRecording() }
        stopMicrophone()
        removeStem()
        loop = nil
        player.karaokePracticeRate = nil
        player.applyPlaybackRate()
        let control = engine.karaokeControl
        control.isActive = false
        control.bridgesStem = false
        control.capturesVocal = false
        engine.applyKaraokePitch(cents: 0)
        player.setKaraokeSessionActive(false)
    }

    /// Switches playback to the effects graph, which karaoke needs.
    func useEffectsOutput() {
        player.playbackSettings.outputMode = .effects
    }

    // MARK: - Ticking

    private func tick() {
        let song = player.currentSong
        availability = KaraokeAvailability.resolve(
            hasSong: song != nil,
            isAppleMusic: player.isAppleMusicMode,
            isCasting: player.isCastingMode,
            isHighFidelityOutput: player.playbackSettings.outputMode == .highFidelity
        )
        if song?.id != songID {
            songDidChange(to: song)
        }
        updateStem()
        updateWordTiming()
        applyRenderSettings()
        isEffectivelyMono = !isStemActive && engine.karaokeControl.isEffectivelyMono
        tickCount &+= 1
        if isStemActive, tickCount % 5 == 0 {
            alignStemIfIdle()
        }
        followLoop()

        // A take ends when playback stays paused. Resuming can take a moment
        // (a seek, a restart after the song ended), so a start is given time.
        if isRecording, !player.isPlaying {
            pausedRecordingTicks += 1
            if pausedRecordingTicks >= Self.recordingPauseTicks { finishRecording() }
        } else {
            pausedRecordingTicks = 0
        }
        if microphoneState == .on {
            canMonitor = AudioSessionManager.shared.outputRouteSupportsMicrophoneMonitoring
            if !canMonitor, isMonitoring { isMonitoring = false }
            assistRouteAllows = canMonitor || AudioSessionManager.shared.outputRouteIsBluetooth
            analyzeIfIdle()
        }
    }

    private func applyRenderSettings() {
        let control = engine.karaokeControl
        let processes = isActive && availability == .available && engine.supportsKaraokeVocalReduction
        let reduces = processes && !isPlayingInstrumental
        // With an AI stem loaded the graph subtracts it instead.
        control.isActive = reduces && !isStemActive
        control.bridgesStem = reduces && isStemActive
        control.capturesVocal = reduces && microphoneState == .on
        let time = player.interpolatedTime()
        let factor = KaraokeDuetGatePolicy.reductionFactor(windows: windows, part: part, at: time)
        if !vocalAssistApplies { vocalAssist.standDown() }
        let assist = vocalAssist.advance(to: time)
        control.reduction = Float((1 - vocalLevel) * assist) * factor
        let assisting = vocalAssist.level > 0.5
        if assisting != isVocalAssisting { isVocalAssisting = assisting }
        if vocalAssist.isSuppressed != isVocalAssistSuppressed { isVocalAssistSuppressed = vocalAssist.isSuppressed }
        engine.applyKaraokePitch(
            cents: processes ? KaraokeKeyShiftPolicy.cents(forSemitones: keyShift) : 0
        )
    }

    private var vocalAssistApplies: Bool {
        vocalAssistEnabled && microphoneState == .on && assistRouteAllows
            && !isPlayingInstrumental && player.isPlaying
    }

    private func songDidChange(to song: Song?) {
        if let song, song.id == carriedSongID {
            // Same performance, other recording of it: keep lyrics and score.
            carriedSongID = nil
            songID = song.id
            isPlayingInstrumental = song.id != pairedOriginal?.id
            referenceTrack.removeAll()
            return
        }
        carriedSongID = nil
        pairedOriginal = nil
        vocalAssist.reset()
        loop = nil
        instrumentalCompanion = nil
        wordTimingTask?.cancel()
        wordTimingTask = nil
        wordTimingSongID = nil
        usesInferredWordTiming = false
        isPlayingInstrumental = false
        lyricsBorrowedFromTitle = nil
        companionTask?.cancel()
        concludePerformance()
        if isRecording { finishRecording() }
        songID = song?.id
        songTitle = song?.title ?? ""
        artistName = song?.artistName ?? ""
        lyrics = []
        stageLines = []
        windows = []
        hasDuetParts = false
        part = .all
        pitchHistory = []
        referenceTrack.removeAll()
        rebuildScorer()
        guard let song else {
            loadLyrics(for: nil)
            return
        }
        let target = Self.companionCandidate(song)
        let playsBackingTrack = KaraokeCompanionPolicy.isInstrumental(target)
        isPlayingInstrumental = playsBackingTrack
        if playsBackingTrack {
            // Its own file rarely has lyrics; wait for the original's.
            isLoadingLyrics = true
        } else {
            loadLyrics(for: song)
        }
        findCompanion(for: song, target: target, playsBackingTrack: playsBackingTrack)
    }

    nonisolated static func companionCandidate(_ song: Song) -> KaraokeCompanionCandidate {
        KaraokeCompanionCandidate(
            id: song.id,
            title: song.title,
            artistName: song.artistName,
            albumTitle: song.albumTitle,
            duration: song.duration,
            filePath: song.filePath,
            sourceID: song.sourceID
        )
    }

    /// Looks the library over off the main actor: the backing track of a sung
    /// song, or the sung original of a backing track.
    private func findCompanion(for song: Song, target: KaraokeCompanionCandidate, playsBackingTrack: Bool) {
        guard let library = player.library else {
            if playsBackingTrack { loadLyrics(for: song) }
            return
        }
        let songs = library.visibleSongs
        let expectedID = song.id
        companionTask = Task { @MainActor [weak self] in
            let matchID = await Task.detached(priority: .utility) { () -> String? in
                let candidates = songs.map(KaraokeSession.companionCandidate)
                let match = playsBackingTrack
                    ? KaraokeCompanionPolicy.original(for: target, in: candidates)
                    : KaraokeCompanionPolicy.instrumental(for: target, in: candidates)
                return match?.id
            }.value
            guard !Task.isCancelled, let self, self.songID == expectedID else { return }
            let match = matchID.flatMap { library.song(id: $0) }
            if playsBackingTrack {
                if let original = match {
                    self.pairedOriginal = original
                    self.lyricsBorrowedFromTitle = original.title
                    self.loadLyrics(for: original, expectedSongID: expectedID)
                } else {
                    self.loadLyrics(for: song)
                }
            } else {
                self.instrumentalCompanion = match
            }
        }
    }

    // MARK: - AI separation

    /// Loads, prepares or drops the AI stem to match what is playing.
    private func updateStem() {
        let song = player.currentSong
        let wanted = aiSeparationEnabled
            && separation.modelState == .ready
            && availability == .available
            && engine.supportsKaraokeVocalReduction
            && !isPlayingInstrumental
            ? song : nil
        guard let wanted else {
            if stemSongID != nil { removeStem() }
            return
        }
        let graphRate = engine.outputFormat?.sampleRate ?? 0
        if stemSongID == wanted.id, stemTrack.map({ abs($0.sampleRate - graphRate) < 0.5 }) ?? true {
            return
        }
        if stemSongID != wanted.id || stemTrack != nil {
            removeStem()
        }
        switch separation.state(for: wanted) {
        case .ready:
            guard graphRate > 0, stemLoadTask == nil else { return }
            stemSongID = wanted.id
            stemLoadTask = Task { @MainActor [weak self] in
                guard let self else { return }
                let track = await self.separation.loadStem(for: wanted, graphSampleRate: graphRate)
                self.stemLoadTask = nil
                guard self.stemSongID == wanted.id, let track else {
                    if self.stemSongID == wanted.id { self.stemSongID = nil }
                    return
                }
                self.stemTrack = track
                self.engine.karaokeControl.installStem(track)
                self.isStemActive = true
                plog("🎤 Karaoke: AI stem loaded frames=\(track.frames) rate=\(Int(track.sampleRate))")
                self.lockPolicy.reset()
            }
        case .idle:
            if let sourceManager = player.sourceManager {
                separation.prepare(wanted, sourceManager: sourceManager)
            }
        case .separating, .unsupported, .failed:
            // A failure is retried only when the user asks.
            break
        }
    }

    /// The separation state of what is playing, for the stage.
    var currentSeparationState: KaraokeSeparationService.SongState? {
        player.currentSong.map { separation.state(for: $0) }
    }

    func retrySeparation() {
        guard let song = player.currentSong, let sourceManager = player.sourceManager else { return }
        separation.prepare(song, sourceManager: sourceManager)
    }

    private func removeStem() {
        stemLoadTask?.cancel()
        stemLoadTask = nil
        stemSongID = nil
        // Withdraw it from the render thread first, then keep the samples
        // alive a moment: a render cycle may already hold their address.
        engine.karaokeControl.installStem(nil)
        if let track = stemTrack {
            retiredStems.append(track)
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(2))
                self?.retiredStems.removeAll { $0 === track }
            }
        }
        stemTrack = nil
        isStemActive = false
        isStemLocked = false
        lockPolicy.reset()
    }

    /// Correlates the newest playback with the stem off the main actor and
    /// publishes the offset once two matches agree.
    private func alignStemIfIdle() {
        guard !isAligning, let track = stemTrack, player.isPlaying else { return }
        let control = engine.karaokeControl
        let epoch = control.currentEpoch
        if epoch != lockPolicyEpoch {
            lockPolicy.reset()
            lockPolicyEpoch = epoch
        }
        isStemLocked = control.isStemLocked
        let window = 8_192
        guard let live = control.inputRing.latestWindow(window) else { return }
        let rate = track.sampleRate
        // The window ends at what was just rendered, roughly the song time.
        let predicted = Int(player.interpolatedTime() * rate) - window
        let radius = Int(0.3 * rate)
        isAligning = true
        Task { @MainActor [weak self] in
            let match = await Task.detached(priority: .utility) { () -> KaraokeStemAligner.Match? in
                guard let range = KaraokeStemAligner.searchRange(
                    stemLength: track.frames,
                    windowLength: window,
                    predictedIndex: predicted,
                    radius: radius
                ) else { return nil }
                return KaraokeStemAligner.match(
                    live: live.samples,
                    excerpt: track.monoExcerpt(range),
                    excerptStart: range.lowerBound
                )
            }.value
            guard let self else { return }
            self.isAligning = false
            guard self.stemTrack === track,
                  control.currentEpoch == epoch,
                  let match,
                  match.confidence >= KaraokeStemAligner.lockConfidence else { return }
            let delta = match.stemIndex - (live.endIndex - window)
            if let adopted = self.lockPolicy.record(delta: delta) {
                control.publishLock(delta: adopted, epoch: epoch)
                plog("🎤 Karaoke: stem locked delta=\(adopted) confidence=\(String(format: "%.2f", match.confidence))")
            }
            self.isStemLocked = control.isStemLocked
        }
    }

    // MARK: - Backing track

    /// Plays the library's backing track from the same position; lyrics and
    /// the running score carry over.
    func switchToInstrumental() {
        guard let companion = instrumentalCompanion, let original = player.currentSong else { return }
        pairedOriginal = original
        switchTrack(to: companion)
    }

    /// Goes back to the sung original from its backing track.
    func switchToOriginal() {
        guard let original = pairedOriginal, player.currentSong?.id != original.id else { return }
        switchTrack(to: original)
    }

    /// Whether the switch button applies, and which way it points.
    var canToggleBackingTrack: Bool {
        !isSwitchingTrack && (instrumentalCompanion != nil || (isPlayingInstrumental && pairedOriginal != nil))
    }

    func toggleBackingTrack() {
        if isPlayingInstrumental {
            switchToOriginal()
        } else {
            switchToInstrumental()
        }
    }

    private func switchTrack(to song: Song) {
        // The graph can be rebuilt for the new file, which drops the tap.
        if isRecording { finishRecording() }
        let position = player.interpolatedTime()
        let wasPlaying = player.isPlaying
        let companionForReturn = instrumentalCompanion ?? player.currentSong
        carriedSongID = song.id
        isSwitchingTrack = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.player.play(song: song)
            if self.player.currentSong?.id == song.id {
                self.player.seek(to: position, startPlaying: wasPlaying)
                // Keep the way back available after the switch.
                if song.id == self.pairedOriginal?.id {
                    self.instrumentalCompanion = companionForReturn
                }
            } else {
                self.carriedSongID = nil
            }
            self.isSwitchingTrack = false
        }
    }

    private func loadLyrics(for song: Song?, expectedSongID: String? = nil) {
        lyricsTask?.cancel()
        guard let song, !player.isAppleMusicMode, let sourceManager = player.sourceManager else {
            isLoadingLyrics = false
            return
        }
        isLoadingLyrics = true
        let expectedID = expectedSongID ?? song.id
        lyricsTask = Task { @MainActor [weak self] in
            let loaded = await LyricsLoader.load(for: song, sourceManager: sourceManager)
            guard !Task.isCancelled, let self, self.songID == expectedID else { return }
            self.isLoadingLyrics = false
            self.applyLyrics(loaded)
        }
    }

    private func applyLyrics(_ loaded: [LyricLine]) {
        lyrics = loaded
        let windows = KaraokeLineWindowPolicy.windows(in: loaded)
        self.windows = windows
        buildStageLines(onsets: nil)
        hasDuetParts = KaraokeDuetGatePolicy.hasDuetParts(loaded)
        wordTimingSongID = nil
        rebuildScorer()
    }

    /// Word-timed rows stay as authored; line-level rows are swept evenly,
    /// or on the vocal's syllable onsets when the AI stem is available.
    private func buildStageLines(onsets: [KaraokeOnset]?) {
        let byIndex = Dictionary(uniqueKeysWithValues: windows.map { ($0.lineIndex, $0) })
        var inferred = false
        stageLines = lyrics.enumerated().map { index, line in
            guard let window = byIndex[index] else { return line }
            if let onsets, let timed = KaraokeWordTimingPolicy.timedLine(line, window: window, onsets: onsets) {
                inferred = true
                return timed
            }
            return KaraokeSweepPolicy.sweepLine(line, window: window)
        }
        usesInferredWordTiming = inferred
    }

    /// Once per song, when its AI stem exists and the lyrics are line-level.
    private func updateWordTiming() {
        guard aiSeparationEnabled,
              let song = player.currentSong,
              song.id == songID,
              wordTimingSongID != song.id,
              wordTimingTask == nil,
              !lyrics.isEmpty,
              lyrics.contains(where: { $0.isSynchronized && !$0.isWordLevel }) else { return }
        // A backing track borrows the original's lyrics and its stem.
        let source = isPlayingInstrumental ? pairedOriginal : song
        guard let source, separation.state(for: source) == .ready else { return }
        let expectedSongID = songID
        let expectedLyrics = lyrics
        wordTimingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let onsets = await self.separation.onsets(for: source)
            self.wordTimingTask = nil
            guard self.songID == expectedSongID, self.lyrics == expectedLyrics else { return }
            self.wordTimingSongID = expectedSongID
            if let onsets, !onsets.isEmpty {
                self.buildStageLines(onsets: onsets)
            }
        }
    }

    private func rebuildScorer() {
        scorer = KaraokeScorer(lines: lyrics, part: hasDuetParts ? part : .all)
        liveLineScore = nil
        runningScore = nil
    }

    // MARK: - Scoring

    private func analyzeIfIdle() {
        guard !isAnalyzing else { return }
        isAnalyzing = true
        let analyzer = self.analyzer
        let vocalRate = engine.outputFormat?.sampleRate ?? 0
        let microphoneRate = microphone.sampleRate
        let time = player.interpolatedTime()
        // Wall-clock latency covers less of the song while slowed down.
        let lag = (microphone.inputLatency + engine.outputPresentationLatency) * practiceRate
        let expectedSongID = songID
        Task { @MainActor [weak self] in
            let reading = await analyzer.analyze(
                vocalSampleRate: vocalRate,
                microphoneSampleRate: microphoneRate
            )
            guard let self else { return }
            self.isAnalyzing = false
            guard self.isActive, self.songID == expectedSongID, self.player.isPlaying else { return }
            self.record(reading, at: time, microphoneLag: lag)
        }
    }

    private func record(_ reading: KaraokePitchAnalyzer.Reading, at time: TimeInterval, microphoneLag: TimeInterval) {
        // The reference comes from before the key change; the singer follows
        // the shifted key.
        let shift = Double(availability == .available ? keyShift : 0)
        referenceTrack.append(time: time, midiNote: reading.reference.map { $0 + shift })
        // The voice heard now answers audio rendered `lag` earlier.
        let sungTime = time - microphoneLag
        let reference = referenceTrack.note(at: sungTime)
        if !isPracticing {
            scorer.record(time: sungTime, reference: reference, sung: reading.sung)
        }
        if vocalAssistApplies {
            vocalAssist.observe(
                time: sungTime,
                inOwnLine: KaraokeVocalAssistPolicy.isOwnLine(windows: windows, part: part, at: sungTime),
                sung: reading.sung,
                reference: reference
            )
        }

        pitchHistory.append(PitchPoint(time: sungTime, reference: reference, sung: reading.sung))
        let cutoff = sungTime - Self.pitchHistoryDuration
        if let firstKept = pitchHistory.firstIndex(where: { $0.time >= cutoff }), firstKept > 0 {
            pitchHistory.removeFirst(firstKept)
        } else if pitchHistory.last.map({ $0.time < cutoff }) == true {
            pitchHistory.removeAll()
        }
        liveLineScore = scorer.lineScore(at: sungTime)
        let summary = scorer.summary()
        runningScore = summary.isEmpty ? nil : summary.totalScore
    }

    /// Publishes the finished song's score for the result card.
    private func concludePerformance() {
        guard microphoneState == .on || lastRecordingURL != nil else { return }
        let summary = scorer.summary()
        guard !summary.isEmpty else { return }
        let bestText = summary.bestLine.flatMap { best in
            lyrics.indices.contains(best.lineIndex) ? lyrics[best.lineIndex].text : nil
        }
        completedPerformance = KaraokePerformance(
            songTitle: songTitle,
            artistName: artistName,
            summary: summary,
            bestLineText: bestText,
            recordingURL: nil
        )
    }

    /// Shows the result card for what has been sung so far.
    func finishPerformance() {
        if isRecording { finishRecording() }
        concludePerformance()
        rebuildScorer()
    }

    // MARK: - Microphone

    func toggleMicrophone() {
        switch microphoneState {
        case .on, .starting:
            stopMicrophone()
        case .off, .denied, .unavailable:
            startMicrophone()
        }
    }

    private func startMicrophone() {
        microphoneState = .starting
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.microphone.start()
                guard self.isActive else {
                    self.microphone.stop()
                    return
                }
                self.microphoneState = .on
                self.canMonitor = AudioSessionManager.shared.outputRouteSupportsMicrophoneMonitoring
                self.isMonitoring = self.isMonitoring && self.canMonitor
                self.rebuildScorer()
                self.applyRenderSettings()
            } catch KaraokeMicrophone.StartError.permissionDenied {
                self.microphoneState = .denied
            } catch {
                plog("⚠️ Karaoke: microphone failed to start: \(error.localizedDescription)")
                self.microphoneState = .unavailable
            }
        }
    }

    private func stopMicrophone() {
        if isRecording { finishRecording() }
        microphone.stop()
        microphoneState = .off
        isMonitoring = false
        pitchHistory = []
        liveLineScore = nil
        applyRenderSettings()
    }

    // MARK: - Recording

    var canRecord: Bool {
        microphoneState == .on && availability == .available && engine.karaokeRecordingTapNode != nil
            && !isPracticing
    }

    // MARK: - Practice

    /// Loops the line being sung (or the next one), or stops looping.
    func toggleLoop() {
        if loop != nil {
            loop = nil
            return
        }
        guard let created = KaraokePracticePolicy.loop(windows: windows, at: player.interpolatedTime()) else { return }
        if isRecording { finishRecording() }
        loop = created
        loopJumpIssuedAt = nil
    }

    /// Adds the following line to the loop.
    func extendLoop() {
        guard let loop, let extended = KaraokePracticePolicy.extended(loop, windows: windows) else { return }
        self.loop = extended
    }

    var canExtendLoop: Bool {
        guard let loop else { return false }
        return loop.lastWindow + 1 < windows.count
    }

    #if DEBUG
    /// `PRIMUSE_DEBUG_KARAOKE_PRACTICE=<rate>`: a few seconds in, slows down
    /// to `rate` and loops the line being sung.
    private func startDebugPractice() {
        guard let value = ProcessInfo.processInfo.environment["PRIMUSE_DEBUG_KARAOKE_PRACTICE"],
              let rate = Double(value) else { return }
        Task { @MainActor [weak self] in
            for _ in 0..<60 {
                try? await Task.sleep(for: .seconds(1))
                guard let self, self.isActive else { return }
                guard self.player.isPlaying, self.player.interpolatedTime() > 3, !self.windows.isEmpty else { continue }
                self.practiceRate = rate
                self.toggleLoop()
                plog("🧪 Karaoke: practice rate=\(rate) loop=\(String(describing: self.loop))")
                return
            }
        }
    }
    #endif

    private func applyPracticeRate() {
        player.karaokePracticeRate = practiceRate < 1 ? Float(practiceRate) : nil
        player.applyPlaybackRate()
    }

    private func followLoop() {
        guard let loop, player.isPlaying else { return }
        let time = player.interpolatedTime()
        if let issued = loopJumpIssuedAt {
            guard time >= loop.end, Date().timeIntervalSince(issued) < 2 else {
                loopJumpIssuedAt = nil
                return
            }
            return
        }
        switch KaraokePracticePolicy.action(for: loop, at: time) {
        case .none:
            break
        case .jumpBack:
            loopJumpIssuedAt = Date()
            plog("🎤 Karaoke: loop back to \(String(format: "%.1f", loop.start))s from \(String(format: "%.1f", time))s")
            player.seek(to: loop.start, startPlaying: true)
        case .leave:
            self.loop = nil
        }
    }

    func toggleRecording() {
        if isRecording {
            finishRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        guard canRecord, let node = engine.karaokeRecordingTapNode else { return }
        let directory = FileManager.default.temporaryDirectory
        let token = UUID().uuidString
        let accompanimentURL = directory.appendingPathComponent("karaoke-\(token)-accompaniment.caf")
        let voiceURL = directory.appendingPathComponent("karaoke-\(token)-voice.caf")
        do {
            let format = node.outputFormat(forBus: 0)
            let writer = try KaraokeTakeWriter(url: accompanimentURL, format: format)
            try microphone.startTake(url: voiceURL)
            KaraokeTap.installWriter(on: node, format: format, writer: writer)
            accompanimentWriter = writer
            accompanimentTapNode = node
            isRecording = true
            pausedRecordingTicks = 0
            recordingFailed = false
            lastRecordingURL = nil
            if !player.isPlaying { player.togglePlayPause() }
        } catch {
            plog("⚠️ Karaoke: recording failed to start: \(error.localizedDescription)")
            _ = microphone.finishTake()
            recordingFailed = true
        }
    }

    private func finishRecording() {
        guard isRecording else { return }
        isRecording = false
        accompanimentTapNode?.removeTap(onBus: 0)
        accompanimentTapNode = nil
        let accompanimentFirst = accompanimentWriter?.finish()
        let accompanimentURL = accompanimentWriter?.url
        accompanimentWriter = nil
        let voice = microphone.finishTake()
        guard let accompanimentURL, let accompanimentFirst, let voice else {
            recordingFailed = true
            return
        }

        let title = songTitle.isEmpty ? "Karaoke" : songTitle
        let destination = KaraokeMixdown.recordingsDirectory
            .appendingPathComponent(Self.recordingFileName(title: title, date: Date()))
        let outputLatency = engine.outputPresentationLatency
        let inputLatency = microphone.inputLatency
        isMixingRecording = true
        Task { @MainActor [weak self] in
            let result: URL?
            do {
                result = try await KaraokeMixdown.mix(
                    accompaniment: .init(url: accompanimentURL, firstHostSeconds: accompanimentFirst),
                    voice: .init(url: voice.url, firstHostSeconds: voice.firstHostSeconds),
                    outputLatency: outputLatency,
                    inputLatency: inputLatency,
                    voiceGain: 1,
                    destination: destination
                )
            } catch {
                plog("⚠️ Karaoke: mixdown failed: \(error.localizedDescription)")
                result = nil
            }
            try? FileManager.default.removeItem(at: accompanimentURL)
            try? FileManager.default.removeItem(at: voice.url)
            guard let self else { return }
            self.isMixingRecording = false
            self.lastRecordingURL = result
            self.recordingFailed = result == nil
            if var performance = self.completedPerformance, performance.recordingURL == nil {
                performance.recordingURL = result
                self.completedPerformance = performance
            }
        }
    }

    static func recordingFileName(title: String, date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let safeTitle = title
            .components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>"))
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return "\(safeTitle.prefix(80)) \(formatter.string(from: date)).m4a"
    }

    func deleteRecording(at url: URL) {
        try? FileManager.default.removeItem(at: url)
        if lastRecordingURL == url { lastRecordingURL = nil }
        if completedPerformance?.recordingURL == url {
            completedPerformance?.recordingURL = nil
        }
    }
}
