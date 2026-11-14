import AVFoundation
import Foundation
import Observation
import PrimuseKit
#if canImport(UIKit)
import UIKit
#endif

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

    /// A step the singer has to take before finish or record can work.
    enum TransportHint: Equatable {
        case finishNeedsMicrophone
        case finishNeedsSinging
        case recordNeedsMicrophone
        case practicing
    }

    struct PitchPoint: Equatable {
        var time: TimeInterval
        var reference: Double?
        var sung: Double?
    }

    static let vocalLevelKey = "karaokeVocalLevel"
    static let aiSeparationKey = "karaokeAISeparationEnabled"
    static let vocalAssistKey = "karaokeVocalAssistEnabled"
    static let tuningExpandedKey = "karaokeTuningExpanded"
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

    /// 实际听到的调: 播放速度旁的整体升降调(#332)加上舞台上的这一份。舞台上写的是它,
    /// 「原调」就是歌曲本来的调;两份在引擎里各存各的,写进节点的是和。
    var heardKeyShift: Int {
        PlaybackPitchPolicy.combinedSemitones(user: player.requestedPitchSemitones, karaoke: keyShift)
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
    private(set) var stageLyrics = KaraokeLyricsSnapshot()
    var stageLines: [LyricLine] { stageLyrics.lines }
    var windows: [KaraokeLineWindow] { stageLyrics.windows }
    var hasDuetParts: Bool { stageLyrics.hasDuetParts }
    private(set) var isLoadingLyrics = false
    /// The library's instrumental version of the playing song, when one exists.
    private(set) var instrumentalCompanion: Song?
    /// What is playing is an instrumental (a paired companion or a backing
    /// track played directly): nothing to reduce, lyrics come from the original.
    private(set) var isPlayingInstrumental = false
    /// Title of the sung original the lyrics were borrowed from.
    private(set) var lyricsBorrowedFromTitle: String?
    private(set) var isSwitchingTrack = false

    /// Use the AI-separated vocal. Off until the user asks for it; turning
    /// it on is what fetches the model, so the 80 MB download is never a surprise.
    var aiSeparationEnabled: Bool {
        didSet {
            defaults.set(aiSeparationEnabled, forKey: Self.aiSeparationKey)
            if aiSeparationEnabled {
                separation.downloadModel()
            } else {
                removeStem()
            }
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
    /// The stage shows the key, speed, AI and other tuning rows, not just
    /// the one-line summary of them. Remembered across visits.
    var isTuningExpanded: Bool {
        didSet { defaults.set(isTuningExpanded, forKey: Self.tuningExpandedKey) }
    }
    /// Assist gave up for this song: the microphone hears the playback.
    private(set) var isVocalAssistSuppressed = false
    /// The AI stem for this song is loaded into the playback graph.
    private(set) var isStemActive = false
    /// The stem is aligned with what is playing and being subtracted.
    private(set) var isStemLocked = false
    /// Line-level lyrics are being swept word by word on the sung vocal.
    var usesInferredWordTiming: Bool { stageLyrics.usesInferredWordTiming }

    private(set) var microphoneState: MicrophoneState = .off
    private(set) var canMonitor = false
    var isMonitoring = false {
        didSet { microphone.monitorVolume = isMonitoring && canMonitor ? 1 : 0 }
    }
    private(set) var pitchHistory: [PitchPoint] = []
    private(set) var liveLineScore: KaraokeLineScore?
    private(set) var runningScore: Int?
    var completedPerformance: KaraokePerformance?
    /// Why the last tap on finish or record had nothing to do; shown for a
    /// moment instead of the button silently doing nothing.
    private(set) var transportHint: TransportHint?
    @ObservationIgnored private var transportHintTask: Task<Void, Never>?

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
    /// Songs whose failed separation this visit already retried on its own.
    @ObservationIgnored private var autoRetriedSeparationSongIDs: Set<String> = []
    @ObservationIgnored private var lockPolicy = KaraokeStemLockPolicy()
    @ObservationIgnored private var lockPolicyEpoch = -1
    /// 开着 ReplayGain 时人声轨要按播放的音量缩放再减(`KaraokeRenderControl.stemScale`)。
    @ObservationIgnored private var stemGain = KaraokeStemGainEstimator()
    /// 「只听伴奏」把人声轨连同对齐结果交给了伴唱:收尾时别把它从消除单元上撤下。
    @ObservationIgnored private var stemHandedToSingAlong = false
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

    /// The switch only reads as on when it can take effect or is on its way:
    /// with the model gone (never fetched, or deleted) it starts off. A model
    /// already on the device from before the switch defaulted to off keeps it on.
    private static func initialAISeparationEnabled(
        stored: Bool?,
        modelState: KaraokeSeparationService.ModelState
    ) -> Bool {
        switch modelState {
        case .ready: stored ?? true
        case .downloading: stored ?? false
        case .notDownloaded, .failed, .unsupportedSystem: false
        }
    }

    init(player: AudioPlayerService, defaults: UserDefaults = .standard) {
        self.player = player
        engine = player.audioEngine
        self.defaults = defaults
        vocalLevel = defaults.object(forKey: Self.vocalLevelKey) as? Double ?? Self.defaultVocalLevel
        aiSeparationEnabled = Self.initialAISeparationEnabled(
            stored: defaults.object(forKey: Self.aiSeparationKey) as? Bool,
            modelState: KaraokeSeparationService.shared.modelState
        )
        vocalAssistEnabled = defaults.object(forKey: Self.vocalAssistKey) as? Bool ?? true
        isTuningExpanded = defaults.bool(forKey: Self.tuningExpandedKey)
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
        stemHandedToSingAlong = false
        // 伴唱开着时先把它挂的人声轨撤下,舞台这一拍再装自己的(两边共用一个消除单元)。
        KaraokeSingAlong.shared.karaokeWillStart()
        engine.karaokeControl.stemFadeDuration = 0
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
        transportHintTask?.cancel()
        transportHintTask = nil
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
        if !stemHandedToSingAlong { control.stemScale = 1 }
        engine.applyKaraokePitch(cents: 0)
        player.setKaraokeSessionActive(false)
        // 舞台关了,开着的伴唱接回来(「只听伴奏」交过来的人声轨在这一拍里接上)。
        KaraokeSingAlong.shared.karaokeDidStop()
    }

    /// 「只听伴奏」:打开伴唱(原唱音量用它自己记住的那一档),把已经装好、对齐好的人声轨原样
    /// 交给它,再像关舞台一样收掉麦克风、打分、录音、练习与升降调。人声轨一直挂在消除单元上、
    /// 锁定也不作废,所以交接时不会先漏一下原唱。舞台还没有人声轨(还在分离、没开 AI)时
    /// 伴唱自己去装。之后由调用方按各自的方式离开舞台。
    func handOffToSingAlong() {
        guard isActive else { return }
        let singAlong = KaraokeSingAlong.shared
        singAlong.setEnabled(true)
        if KaraokeSingAlongPolicy.handsStemOver(
            isSingAlongEnabled: singAlong.isEnabled,
            stageHasStem: isStemActive && stemTrack != nil,
            stemSongMatchesPlaying: stemSongID != nil && stemSongID == player.currentSong?.id,
            isPlayingInstrumental: isPlayingInstrumental
        ), let track = stemTrack, let songID = stemSongID {
            singAlong.receiveStem(.init(
                track: track,
                songID: songID,
                lockPolicy: lockPolicy,
                lockPolicyEpoch: lockPolicyEpoch,
                gain: stemGain
            ))
            stemHandedToSingAlong = true
            stemLoadTask?.cancel()
            stemLoadTask = nil
            stemTrack = nil
            stemSongID = nil
            isStemActive = false
            isStemLocked = false
            plog("🎤 Karaoke: handing the stem over to sing-along \(songID.prefix(8))")
        }
        stop()
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
        control.stemScale = Float(stemGain.scale(appliesTo: player))
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
        isPlayingInstrumental = false
        lyricsBorrowedFromTitle = nil
        companionTask?.cancel()
        concludePerformance()
        if isRecording { finishRecording() }
        songID = song?.id
        songTitle = song?.title ?? ""
        artistName = song?.artistName ?? ""
        lyrics = []
        stageLyrics = KaraokeLyricsSnapshot()
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
        case .failed:
            // Once per visit it tries again by itself: the usual causes are
            // one-offs (the app was in the background, the file could not be
            // fetched just then). After that the retry button is the way.
            guard !autoRetriedSeparationSongIDs.contains(wanted.id),
                  let sourceManager = player.sourceManager else { return }
            autoRetriedSeparationSongIDs.insert(wanted.id)
            plog("🎤 Karaoke: retrying failed separation once \(wanted.id.prefix(8))")
            separation.prepare(wanted, sourceManager: sourceManager)
        case .preparing, .separating, .unsupported:
            break
        }
    }

    /// Why the playing song's separation failed, if it did.
    var currentSeparationFailureReason: String? {
        player.currentSong.flatMap { separation.songFailureReasons[$0.id] }
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
        // 交给伴唱的那一份已经不归舞台:留在消除单元上,由伴唱接着减。
        if !stemHandedToSingAlong {
            engine.karaokeControl.installStem(nil)
        }
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
        stemGain.reset()
        if !stemHandedToSingAlong {
            engine.karaokeControl.stemScale = 1
        }
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
            let result = await KaraokeStemAlignmentResult.compute(
                track: track,
                live: live.samples,
                windowLength: window,
                predictedIndex: predicted,
                radius: radius
            )
            guard let self else { return }
            self.isAligning = false
            guard self.stemTrack === track,
                  control.currentEpoch == epoch,
                  let result,
                  result.match.confidence >= KaraokeStemAligner.lockConfidence else { return }
            let match = result.match
            let delta = match.stemIndex - (live.endIndex - window)
            if let adopted = self.lockPolicy.record(delta: delta) {
                control.publishLock(delta: adopted, epoch: epoch)
                plog("🎤 Karaoke: stem locked delta=\(adopted) confidence=\(String(format: "%.2f", match.confidence))")
            }
            if let gain = result.gain, delta == self.lockPolicy.lockedDelta {
                self.stemGain.record(gain)
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
        buildStageLines(onsets: nil)
        wordTimingSongID = nil
        rebuildScorer()
    }

    /// Word-timed rows stay as authored; line-level rows are swept evenly,
    /// or on the vocal's syllable onsets when the AI stem is available.
    private func buildStageLines(onsets: [KaraokeOnset]?) {
        stageLyrics = KaraokeLyricsSnapshot(lines: lyrics, onsets: onsets)
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
        // the shifted key — the global one next to the speed included.
        let shift = Double(availability == .available ? heardKeyShift : 0)
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

    /// Publishes the finished song's score for the result card. When the
    /// song changes, only if the microphone is still on (or a take was
    /// recorded); the finish button shows whatever was sung.
    private func concludePerformance(requiresMicrophone: Bool = true) {
        guard !requiresMicrophone || microphoneState == .on || lastRecordingURL != nil else { return }
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

    /// Nothing scored yet, and what it takes to get a score.
    var finishBlocker: TransportHint? {
        guard runningScore == nil else { return nil }
        if microphoneState != .on { return .finishNeedsMicrophone }
        return isPracticing ? .practicing : .finishNeedsSinging
    }

    /// Shows the result card for what has been sung so far, or says what is
    /// missing. The score outlives turning the microphone off.
    func finishPerformance() {
        if let blocker = finishBlocker {
            showTransportHint(blocker)
            return
        }
        if isRecording { finishRecording() }
        concludePerformance(requiresMicrophone: false)
        rebuildScorer()
    }

    private func showTransportHint(_ hint: TransportHint) {
        transportHint = hint
        transportHintTask?.cancel()
        transportHintTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.transportHint = nil
        }
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
                self.transportHint = nil
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

    /// Why recording cannot start, when it is a step the singer can take.
    var recordBlocker: TransportHint? {
        guard !isRecording, !canRecord else { return nil }
        if microphoneState != .on { return .recordNeedsMicrophone }
        return isPracticing ? .practicing : nil
    }

    func toggleRecording() {
        if isRecording {
            finishRecording()
        } else if let blocker = recordBlocker {
            showTransportHint(blocker)
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

// MARK: - 对齐(卡拉OK舞台与伴唱共用)

/// 一次对齐的结果:人声轨在哪儿,以及播放信号里含了多少倍的它(`KaraokeStemAligner.gain`)。
struct KaraokeStemAlignmentResult: Sendable {
    let match: KaraokeStemAligner.Match
    let gain: Double?

    /// 在主线程外算:互相关要做几次长 FFT。
    static func compute(
        track: KaraokeStemTrack,
        live: [Float],
        windowLength: Int,
        predictedIndex: Int,
        radius: Int
    ) async -> KaraokeStemAlignmentResult? {
        await Task.detached(priority: .utility) { () -> KaraokeStemAlignmentResult? in
            guard let range = KaraokeStemAligner.searchRange(
                stemLength: track.frames,
                windowLength: windowLength,
                predictedIndex: predictedIndex,
                radius: radius
            ) else { return nil }
            let excerpt = track.monoExcerpt(range)
            guard let match = KaraokeStemAligner.match(
                live: live,
                excerpt: excerpt,
                excerptStart: range.lowerBound
            ) else { return nil }
            let gain = KaraokeStemAligner.gain(
                live: live,
                excerpt: excerpt,
                excerptStart: range.lowerBound,
                stemIndex: match.stemIndex
            )
            return KaraokeStemAlignmentResult(match: match, gain: gain)
        }.value
    }
}

extension KaraokeStemGainEstimator {
    /// 只在开着 ReplayGain 时缩放:不开时消除单元之前的音量本来就是 1,估计里只剩伴奏带来的噪声。
    @MainActor
    func scale(appliesTo player: AudioPlayerService) -> Double {
        player.playbackSettings.replayGainEnabled ? scale : 1
    }
}

// MARK: - 伴唱(#377)

/// 伴唱:平时听歌时把正在放的歌换成 AI 分离出的伴奏,原唱压到选定的音量。不开麦克风、不打分、
/// 歌词照常,跟着播放页走;开关和原唱音量记在本机(模型和分离缓存也都在本机)。
///
/// 和卡拉OK共用分离模型、分离缓存与播放图里的人声消除单元(`AudioEngine.karaokeControl`)。
/// 舞台打开时伴唱先撤下自己挂的人声轨、不再碰那个单元(`karaokeWillStart`),舞台关上后接着来
/// (`karaokeDidStop`)。伴唱只在挂着人声轨时写那个单元,没挂时单元保持默认值。
///
/// 一首歌分离好之前照放原唱;分离好、对齐上以后原唱在约 0.3 秒里淡出。分离要用 GPU,App 在后台时
/// 停着、回前台接着来,所以前台时提前分离接下来两首,锁屏听也能接上。规则在 Kit 的 `KaraokeSingAlongPolicy`。
@MainActor
@Observable
final class KaraokeSingAlong {
    static let shared = KaraokeSingAlong()

    static let enabledKey = "singAlongEnabled"
    static let levelKey = "singAlongVocalLevel"
    /// 原唱淡入淡出的时长(秒)。卡拉OK舞台是一个渲染块里变完,跟手;伴唱是听歌,慢一点不突兀。
    private static let fadeDuration: Float = 0.3
    /// 提前分离接下来的歌,隔多久看一次。
    private static let prefetchCheckInterval: Duration = .seconds(5)

    private(set) var isEnabled: Bool
    private(set) var level: KaraokeSingAlongLevel
    private(set) var phase: KaraokeSingAlongPhase = .off
    /// `phase` 去掉进度:系统菜单读它,分离进度一点点涨时菜单不重建。
    private(set) var menuPhase: KaraokeSingAlongPhase = .off

    @ObservationIgnored private weak var player: AudioPlayerService?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var loopTask: Task<Void, Never>?
    /// 开着的卡拉OK舞台数;大于 0 时伴唱不碰消除单元。
    @ObservationIgnored private var karaokeHolds = 0
    /// 人声轨挂在消除单元上,伴唱此刻占着它。
    @ObservationIgnored private var ownsRenderControl = false
    @ObservationIgnored private var stemSongID: String?
    @ObservationIgnored private var stemTrack: KaraokeStemTrack?
    @ObservationIgnored private var retiredStems: [KaraokeStemTrack] = []
    @ObservationIgnored private var stemLoadTask: Task<Void, Never>?
    /// 关掉、换到放不了伴唱的歌时,原唱先淡回来,再把人声轨撤下。
    @ObservationIgnored private var fadeOutTask: Task<Void, Never>?
    @ObservationIgnored private var lockPolicy = KaraokeStemLockPolicy()
    @ObservationIgnored private var lockPolicyEpoch = -1
    @ObservationIgnored private var stemGain = KaraokeStemGainEstimator()
    @ObservationIgnored private var isAligning = false
    @ObservationIgnored private var lastAlignment: ContinuousClock.Instant?
    /// 伴唱自己发起的分离;跳过去不再要的就取消。卡拉OK舞台、为电视分离的不在这里,不会被取消。
    @ObservationIgnored private var requestedSongIDs: Set<String> = []
    @ObservationIgnored private var retriedSongIDs: Set<String> = []
    /// 人声轨文件读不出来的次数:第一次删掉重分,第二次就当这首分离失败。
    @ObservationIgnored private var loadFailures: [String: Int] = [:]
    @ObservationIgnored private var currentSongID: String?
    @ObservationIgnored private var lastPrefetchCheck: ContinuousClock.Instant?
    @ObservationIgnored private var prefetchTask: Task<Void, Never>?
    @ObservationIgnored private var activityID: UUID?
    @ObservationIgnored private var publishedActivity: PlayerActivityStatus?
    /// 卡拉OK舞台「只听伴奏」交过来、舞台关上那一拍接上的人声轨。
    @ObservationIgnored private var pendingHandoff: StemHandoff?

    /// 卡拉OK舞台「只听伴奏」交过来的人声轨:还挂在消除单元上,锁定(对齐结果)也还有效。
    struct StemHandoff {
        let track: KaraokeStemTrack
        let songID: String
        let lockPolicy: KaraokeStemLockPolicy
        let lockPolicyEpoch: Int
        let gain: KaraokeStemGainEstimator
    }

    /// 只在用到时才碰分离服务(它一建出来就去问托管资源包)。
    private var separation: KaraokeSeparationService { .shared }

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = defaults.bool(forKey: Self.enabledKey)
        level = KaraokeSingAlongLevel(stored: defaults.string(forKey: Self.levelKey))
    }

    // MARK: 开关

    /// App 启动时接上播放器;上次开着就接着开。模型不在了(被删掉、被系统清掉)不自己去下,
    /// 开关回到关。
    func attach(_ player: AudioPlayerService) {
        self.player = player
        guard isEnabled else { return }
        // 问模型在不在要碰托管资源包,不放在启动的那一拍里。
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, self.isEnabled, self.loopTask == nil else { return }
            guard KaraokeSingAlongPolicy.staysEnabledAtLaunch(model: self.modelStatus) else {
                plog("🎤 SingAlong: the AI model is not on this device, turning off")
                self.store(enabled: false)
                return
            }
            self.startLoop()
        }
    }

    var modelStatus: KaraokeSingAlongModelStatus {
        switch separation.modelState {
        case .unsupportedSystem: .unsupportedSystem
        case .notDownloaded: .notDownloaded
        case .downloading(let fraction): .downloading(fraction)
        case .ready: .ready
        case .failed: .failed
        }
    }

    /// 打开即同意下载模型(菜单里打开之前就写明了大小)。这台设备拿不到模型时打不开。
    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        if enabled {
            let model = modelStatus
            guard KaraokeSingAlongPolicy.canEnable(model: model) else { return }
            store(enabled: true)
            if KaraokeSingAlongPolicy.downloadsModelOnEnable(model) {
                separation.downloadModel()
            }
            startLoop()
        } else {
            store(enabled: false)
            stopLoop()
        }
        plog("🎤 SingAlong: \(enabled ? "on" : "off") level=\(level.rawValue)")
    }

    func setLevel(_ newLevel: KaraokeSingAlongLevel) {
        guard newLevel != level else { return }
        level = newLevel
        defaults.set(newLevel.rawValue, forKey: Self.levelKey)
        applyRenderSettings()
    }

    private func store(enabled: Bool) {
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.enabledKey)
    }

    /// 菜单里的「重试」:模型没下下来就重下,这首没分离成就重分。
    func retry() {
        guard isEnabled, let player else { return }
        if separation.modelState == .failed {
            separation.downloadModel()
        } else if let song = player.currentSong {
            if (loadFailures[song.id] ?? 0) >= 2 {
                loadFailures[song.id] = nil
                separation.discardStem(for: song)
            }
            if separation.state(for: song) == .failed {
                requestSeparation(of: song)
            }
        }
        tick()
    }

    /// 为什么没成:模型下载或这首分离失败的原因。
    var failureReason: String? {
        switch menuPhase {
        case .modelFailed:
            return separation.modelFailureReason
        case .songFailed:
            return player?.currentSong.flatMap { separation.songFailureReasons[$0.id] }
        default:
            return nil
        }
    }

    // MARK: 卡拉OK舞台

    /// 卡拉OK舞台要接手消除单元:同一拍里先把伴唱的人声轨撤下,舞台再装自己的。
    func karaokeWillStart() {
        karaokeHolds += 1
        guard karaokeHolds == 1 else { return }
        prefetchTask?.cancel()
        prefetchTask = nil
        if let handoff = pendingHandoff {
            pendingHandoff = nil
            drop(handoff)
        }
        removeStem()
        clearActivity()
        if isEnabled { setPhase(.yieldingToKaraoke) }
    }

    /// 舞台关了:开着伴唱就马上接回来,不等下一拍。
    func karaokeDidStop() {
        karaokeHolds = max(0, karaokeHolds - 1)
        guard karaokeHolds == 0 else { return }
        guard isEnabled else {
            if let handoff = pendingHandoff {
                pendingHandoff = nil
                drop(handoff)
            }
            return
        }
        tick()
    }

    /// 「只听伴奏」:舞台收尾前把人声轨交过来,舞台关上那一拍(`karaokeDidStop` 里的 `tick`)接上。
    func receiveStem(_ handoff: StemHandoff) {
        pendingHandoff = handoff
    }

    // MARK: 每一拍

    private func startLoop() {
        guard loopTask == nil else { return }
        loopTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let interval = self?.tick() else { return }
                try? await Task.sleep(for: interval)
            }
        }
    }

    private func stopLoop() {
        loopTask?.cancel()
        loopTask = nil
        prefetchTask?.cancel()
        prefetchTask = nil
        if let handoff = pendingHandoff {
            pendingHandoff = nil
            drop(handoff)
        }
        releaseRenderControl(fadingOut: true)
        // 关掉以后,为伴唱发起、还没分完的分离不再占 GPU。
        cancelRequestedSeparations(keeping: [])
        currentSongID = nil
        lastPrefetchCheck = nil
        clearActivity()
        setPhase(.off)
    }

    /// 返回到下一拍的间隔:放着歌时 0.25 秒(换歌后尽快换上人声轨、没锁定时尽快对齐),
    /// 暂停时 1 秒。
    @discardableResult
    private func tick() -> Duration {
        guard isEnabled, let player else { return .seconds(1) }
        guard karaokeHolds == 0 else {
            setPhase(.yieldingToKaraoke)
            return .seconds(1)
        }
        let model = modelStatus
        if KaraokeSingAlongPolicy.turnsOff(model: model) {
            plog("🎤 SingAlong: the AI model was removed, turning off")
            setEnabled(false)
            return .seconds(1)
        }
        let song = player.currentSong
        if song?.id != currentSongID {
            currentSongID = song?.id
            songDidChange(player: player)
        }
        let availability = Self.availability(of: player)
        let wantsStem = KaraokeSingAlongPolicy.wantsStem(
            isEnabled: true,
            isKaraokeActive: false,
            availability: availability,
            model: model
        )
        if let handoff = pendingHandoff {
            pendingHandoff = nil
            if wantsStem, handoff.songID == song?.id {
                adopt(handoff)
            } else {
                drop(handoff)
            }
        }
        if let song, wantsStem {
            updateStem(for: song, player: player)
        } else {
            releaseRenderControl(fadingOut: true)
        }
        applyRenderSettings()
        alignIfDue(player: player)

        let isStemLoaded = ownsRenderControl && fadeOutTask == nil && stemSongID != nil && stemSongID == song?.id
        let control = player.audioEngine.karaokeControl
        setPhase(KaraokeSingAlongPolicy.phase(
            isEnabled: true,
            isKaraokeActive: false,
            availability: availability,
            model: model,
            song: isStemLoaded ? nil : song.map(songStatus(of:)),
            hold: song.flatMap(hold(of:)),
            isStemLoaded: isStemLoaded,
            isStemLocked: isStemLoaded && control.isStemLocked
        ))
        updateActivity(songID: song?.id)
        prefetchIfDue(player: player)
        return player.isPlaying ? .milliseconds(250) : .seconds(1)
    }

    private func setPhase(_ newPhase: KaraokeSingAlongPhase) {
        if phase != newPhase { phase = newPhase }
        let coarse = newPhase.withoutProgress
        if menuPhase != coarse { menuPhase = coarse }
    }

    /// 伴唱此刻能不能作用在正在放的东西上;卡拉OK舞台用它决定给不给「只听伴奏」。
    static func availability(of player: AudioPlayerService) -> KaraokeSingAlongAvailability {
        let song = player.currentSong
        let engine = player.audioEngine
        let isHighFidelity = player.outputMode(for: song) == .highFidelity
        // 效果图搭好了却没有消除单元(单元没装上):和系统播放器一样放不了伴唱。
        let lacksVocalUnit = !isHighFidelity && engine.outputFormat != nil && !engine.supportsKaraokeVocalReduction
        return KaraokeSingAlongAvailability.resolve(
            hasSong: song != nil,
            isSpokenWordOrRadio: player.currentItemIsSpokenWord || player.isLiveRadio || player.currentItemIsAmbient,
            isAppleMusic: player.isAppleMusicMode,
            isCasting: player.isCastingMode,
            isHighFidelityOutput: isHighFidelity,
            isSpatialAudio: engine.spatialAudioEnabled,
            isSystemPlayback: player.isSystemMediaPlaybackActive || lacksVocalUnit,
            isMedley: player.isMedleyActive
        )
    }

    private func songStatus(of song: Song) -> KaraokeSingAlongSongStatus {
        if (loadFailures[song.id] ?? 0) >= 2 { return .failed }
        switch separation.state(for: song) {
        case .idle: return .idle
        case .preparing: return .preparing
        case .separating(let fraction): return .separating(fraction)
        case .ready: return .ready
        case .unsupported: return .unsupported
        case .failed: return .failed
        }
    }

    private func hold(of song: Song) -> KaraokeSingAlongHold? {
        switch separation.holdReasons[song.id] {
        case .cooling?: .cooling
        case .background?: .background
        case nil: nil
        }
    }

    // MARK: 换歌

    private func songDidChange(player: AudioPlayerService) {
        let upcoming = player.nextSongsInQueue(count: KaraokeSingAlongPolicy.prefetchDepth)
        let current = player.currentSong.map { [$0] } ?? []
        // 跳过去的歌不再分离,省下 GPU 和流量。
        cancelRequestedSeparations(keeping: Set((current + upcoming).map(\.id)))
        prefetchTask?.cancel()
        prefetchTask = nil
        lastPrefetchCheck = nil
        let keeping = current + upcoming
        Task { @MainActor in
            await KaraokeSeparationService.shared.trimCache(
                maximumBytes: KaraokeSingAlongPolicy.stemCacheLimitBytes,
                keeping: keeping
            )
        }
    }

    private func cancelRequestedSeparations(keeping kept: Set<String>) {
        guard !requestedSongIDs.isEmpty else { return }
        for id in requestedSongIDs.subtracting(kept) {
            separation.cancel(id)
        }
        requestedSongIDs.formIntersection(kept)
    }

    /// 只记自己真正发起的:已经有人在分(卡拉OK舞台、为电视分离)的歌不算。
    private func requestSeparation(of song: Song) {
        guard let sourceManager = player?.sourceManager else { return }
        switch separation.state(for: song) {
        case .idle, .failed: break
        case .preparing, .separating, .ready, .unsupported: return
        }
        separation.prepare(song, sourceManager: sourceManager)
        if separation.state(for: song) == .preparing {
            requestedSongIDs.insert(song.id)
            plog("🎤 SingAlong: separating \(song.id.prefix(8))")
        }
    }

    // MARK: 人声轨

    private func updateStem(for song: Song, player: AudioPlayerService) {
        let engine = player.audioEngine
        let graphRate = engine.outputFormat?.sampleRate ?? 0
        if stemSongID == song.id {
            if let track = stemTrack {
                // 采样率变了(换了输出设备、重建了播放图)才按新采样率重装;其余照用。
                guard graphRate > 0, abs(track.sampleRate - graphRate) >= 0.5 else {
                    cancelFadeOut()
                    return
                }
            } else if stemLoadTask != nil {
                return
            }
        }
        if stemSongID != nil || stemTrack != nil {
            removeStem()
        }
        let status = songStatus(of: song)
        if status == .ready {
            guard graphRate > 0 else { return }
            loadStem(for: song, graphRate: graphRate)
            return
        }
        switch KaraokeSingAlongPolicy.separationRequest(
            for: status,
            alreadyRetried: retriedSongIDs.contains(song.id)
        ) {
        case .start:
            requestSeparation(of: song)
        case .retry:
            retriedSongIDs.insert(song.id)
            plog("🎤 SingAlong: retrying failed separation once \(song.id.prefix(8))")
            requestSeparation(of: song)
        case .skip:
            break
        }
    }

    private func loadStem(for song: Song, graphRate: Double) {
        stemSongID = song.id
        stemLoadTask = Task { @MainActor [weak self] in
            let track = await KaraokeSeparationService.shared.loadStem(for: song, graphSampleRate: graphRate)
            guard !Task.isCancelled, let self, self.stemSongID == song.id else { return }
            self.stemLoadTask = nil
            guard let track else {
                // 文件读不出来:删掉重分一次;再读不出来就当这首分离失败,菜单里能重试。
                self.stemSongID = nil
                let failures = (self.loadFailures[song.id] ?? 0) + 1
                self.loadFailures[song.id] = failures
                plog("⚠️ SingAlong: stem for \(song.id.prefix(8)) could not be read (\(failures))")
                KaraokeSeparationService.shared.discardStem(for: song)
                return
            }
            guard self.isEnabled, self.karaokeHolds == 0, let player = self.player else {
                self.stemSongID = nil
                return
            }
            self.install(track, control: player.audioEngine.karaokeControl)
            plog("🎤 SingAlong: stem loaded \(song.id.prefix(8)) frames=\(track.frames) rate=\(Int(track.sampleRate))")
        }
    }

    /// 接上舞台交过来的人声轨:不重装、不推进对齐的轮次,舞台的锁定接着用,原唱不会先漏出来;
    /// 减去的量从舞台的人声音量在 0.3 秒里过渡到伴唱这一档。
    private func adopt(_ handoff: StemHandoff) {
        removeStem()
        stemTrack = handoff.track
        stemSongID = handoff.songID
        lockPolicy = handoff.lockPolicy
        lockPolicyEpoch = handoff.lockPolicyEpoch
        stemGain = handoff.gain
        lastAlignment = nil
        ownsRenderControl = true
        applyRenderSettings()
        let locked = player?.audioEngine.karaokeControl.isStemLocked ?? false
        plog("🎤 SingAlong: took over the karaoke stage's stem \(handoff.songID.prefix(8)) locked=\(locked)")
    }

    /// 交过来却用不上(换了歌、伴唱没开着、又开了一场卡拉OK):从消除单元上撤下,样本留一会儿。
    private func drop(_ handoff: StemHandoff) {
        if let control = player?.audioEngine.karaokeControl {
            control.installStem(nil)
            control.bridgesStem = false
            control.stemScale = 1
            control.stemFadeDuration = 0
            control.reduction = 1
        }
        retire(handoff.track)
    }

    private func retire(_ track: KaraokeStemTrack) {
        retiredStems.append(track)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            self?.retiredStems.removeAll { $0 === track }
        }
    }

    private func install(_ track: KaraokeStemTrack, control: KaraokeRenderControl) {
        stemTrack = track
        lockPolicy.reset()
        stemGain.reset()
        lastAlignment = nil
        control.isActive = false
        control.capturesVocal = false
        control.installStem(track)
        ownsRenderControl = true
        applyRenderSettings()
    }

    /// 伴唱占着消除单元时每拍写一次:原唱留多少、ReplayGain 的比例、淡入淡出的快慢。
    private func applyRenderSettings() {
        guard ownsRenderControl, fadeOutTask == nil, let player else { return }
        let control = player.audioEngine.karaokeControl
        control.isActive = false
        control.capturesVocal = false
        // 对齐前不用普通消除顶着:伴唱是听歌,前奏、间奏被挖空比开口那半秒漏一点原唱更难听。
        control.bridgesStem = false
        control.stemFadeDuration = Self.fadeDuration
        control.reduction = Float(level.reduction)
        control.stemScale = Float(stemGain.scale(appliesTo: player))
    }

    /// 不再挂人声轨:听歌时先让原唱淡回来再撤;换给卡拉OK舞台时立刻撤。
    private func releaseRenderControl(fadingOut: Bool) {
        stemLoadTask?.cancel()
        stemLoadTask = nil
        guard ownsRenderControl, let player else {
            stemSongID = nil
            return
        }
        guard fadingOut else {
            removeStem()
            return
        }
        guard fadeOutTask == nil else { return }
        let control = player.audioEngine.karaokeControl
        control.stemFadeDuration = Self.fadeDuration
        control.reduction = 0
        fadeOutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(Self.fadeDuration * 1000) + 150))
            guard !Task.isCancelled, let self else { return }
            self.fadeOutTask = nil
            self.removeStem()
        }
    }

    /// 淡出途中又要这首的人声轨(开关来回点、可用性闪了一下):接着用,下一次写设置时减回去。
    private func cancelFadeOut() {
        guard let task = fadeOutTask else { return }
        task.cancel()
        fadeOutTask = nil
    }

    private func removeStem() {
        fadeOutTask?.cancel()
        fadeOutTask = nil
        stemLoadTask?.cancel()
        stemLoadTask = nil
        if ownsRenderControl, let player {
            let control = player.audioEngine.karaokeControl
            // 先从渲染线程撤下,样本再留一会儿:可能有一个渲染周期已经拿着它的地址。
            control.installStem(nil)
            control.bridgesStem = false
            control.stemScale = 1
            control.stemFadeDuration = 0
            control.reduction = 1
        }
        ownsRenderControl = false
        if let track = stemTrack {
            retire(track)
        }
        stemTrack = nil
        stemSongID = nil
        lockPolicy.reset()
        stemGain.reset()
        lastAlignment = nil
    }

    // MARK: 对齐

    /// 和卡拉OK舞台同一套互相关对齐;没锁定时每 0.25 秒一次,锁定后每 2 秒复核一次。
    private func alignIfDue(player: AudioPlayerService) {
        guard ownsRenderControl, fadeOutTask == nil, !isAligning,
              let track = stemTrack, player.isPlaying else { return }
        let control = player.audioEngine.karaokeControl
        let epoch = control.currentEpoch
        if epoch != lockPolicyEpoch {
            lockPolicy.reset()
            lockPolicyEpoch = epoch
        }
        let interval = KaraokeSingAlongPolicy.alignmentInterval(
            isLocked: control.isStemLocked,
            needsGainEstimate: player.playbackSettings.replayGainEnabled && !stemGain.isSettled
        )
        let now = ContinuousClock.now
        if let last = lastAlignment, now - last < interval { return }
        let window = 8_192
        guard let live = control.inputRing.latestWindow(window) else { return }
        lastAlignment = now
        let rate = track.sampleRate
        // 窗口末尾就是刚渲染的那一刻,大致是歌里的这一秒。
        let predicted = Int(player.interpolatedTime() * rate) - window
        let radius = Int(0.3 * rate)
        isAligning = true
        Task { @MainActor [weak self] in
            let result = await KaraokeStemAlignmentResult.compute(
                track: track,
                live: live.samples,
                windowLength: window,
                predictedIndex: predicted,
                radius: radius
            )
            guard let self else { return }
            self.isAligning = false
            guard self.stemTrack === track,
                  control.currentEpoch == epoch,
                  let result,
                  result.match.confidence >= KaraokeStemAligner.lockConfidence else { return }
            let delta = result.match.stemIndex - (live.endIndex - window)
            if let adopted = self.lockPolicy.record(delta: delta) {
                control.publishLock(delta: adopted, epoch: epoch)
                plog("🎤 SingAlong: stem locked delta=\(adopted) confidence=\(String(format: "%.2f", result.match.confidence))")
            }
            if let gain = result.gain, delta == self.lockPolicy.lockedDelta {
                self.stemGain.record(gain)
                self.applyRenderSettings()
            }
        }
    }

    // MARK: 提前分离

    /// 前台、设备不热、没开低电量模式时,把接下来的歌先分离好;一次只备一首,
    /// 只备文件已经在本机的(本地源,或已经缓存下来的),不为提前分离整首下载。
    private func prefetchIfDue(player: AudioPlayerService) {
        guard prefetchTask == nil, let sourceManager = player.sourceManager else { return }
        let now = ContinuousClock.now
        if let last = lastPrefetchCheck, now - last < Self.prefetchCheckInterval { return }
        lastPrefetchCheck = now
        let thermal = ProcessInfo.processInfo.thermalState
        guard KaraokeSingAlongPolicy.prefetchesUpcoming(
            current: phase,
            isForeground: Self.isForeground,
            isLowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            isHot: thermal == .serious || thermal == .critical
        ), !hasSeparationInFlight else { return }
        let depth = KaraokeSingAlongPolicy.prefetchDepth
        guard let next = player.nextSongsInQueue(count: depth).first(where: { song in
            song.sourceID != AppleMusicLibraryService.systemSourceID
                && !SpokenWordStore.shared.isSpokenWord(song)
                && song.duration <= KaraokeSeparationService.maximumDuration
                && !KaraokeCompanionPolicy.isInstrumental(KaraokeSession.companionCandidate(song))
                && songStatus(of: song) == .idle
        }) else { return }
        prefetchTask = Task { @MainActor [weak self] in
            var isOnDevice = await sourceManager.directLocalFileURL(for: next) != nil
            if !isOnDevice {
                isOnDevice = await sourceManager.cachedURLForBackgroundRead(for: next) != nil
            }
            guard !Task.isCancelled, let self else { return }
            self.prefetchTask = nil
            guard isOnDevice, self.isEnabled, self.karaokeHolds == 0,
                  self.player?.nextSongsInQueue(count: depth).contains(where: { $0.id == next.id }) == true,
                  self.songStatus(of: next) == .idle else { return }
            plog("🎤 SingAlong: separating upcoming \(next.id.prefix(8)) ahead")
            self.requestSeparation(of: next)
        }
    }

    private var hasSeparationInFlight: Bool {
        requestedSongIDs.contains { id in
            switch separation.songStates[id] {
            case .preparing?, .separating?: true
            default: false
            }
        }
    }

    private static var isForeground: Bool {
        #if canImport(UIKit)
        UIApplication.shared.applicationState == .active
        #else
        true
        #endif
    }

    // MARK: 播放页底部的进度

    /// 分离、下载模型时在播放页底部那行写「伴唱准备中」和进度:用户开着伴唱却还听到原唱,
    /// 得看得出是在准备、不是没起作用。起作用以后就不再占地方。
    private func updateActivity(songID: String?) {
        let progress: Double?
        switch phase {
        // 分离完了、正在装人声轨:一转眼的事(没在放时要等播放图搭好),不挂。
        case .preparing(let fraction, _) where fraction != 1:
            progress = fraction
        case .downloadingModel(let fraction):
            progress = fraction
        default:
            clearActivity()
            return
        }
        let id = activityID ?? UUID()
        activityID = id
        let status = PlayerActivityStatus(
            id: id,
            songID: songID,
            title: String(localized: "sing_along_activity_preparing"),
            progress: progress
        )
        guard status != publishedActivity else { return }
        publishedActivity = status
        PlayerActivityStore.shared.publish(status)
    }

    private func clearActivity() {
        guard let id = activityID else { return }
        PlayerActivityStore.shared.remove(id)
        activityID = nil
        publishedActivity = nil
    }
}
