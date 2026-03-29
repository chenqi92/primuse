import AVFoundation
import Foundation
import MediaPlayer
import PrimuseKit

/// Mutable counter that can be captured by @Sendable closures (e.g. Timer callbacks wrapped in Task).
private final class StepCounter: @unchecked Sendable {
    var value = 0
}

/// Sendable wrapper for AsyncThrowingStream.Iterator to safely transfer across isolation boundaries.
/// The iterator is accessed sequentially: once on MainActor for the first buffer,
/// then exclusively by the decodingTask. Never accessed concurrently.
private final class BufferIteratorBox: @unchecked Sendable {
    private var iterator: AsyncThrowingStream<AVAudioPCMBuffer, Error>.AsyncIterator

    init(_ iterator: AsyncThrowingStream<AVAudioPCMBuffer, Error>.AsyncIterator) {
        self.iterator = iterator
    }

    func next() async throws -> AVAudioPCMBuffer? {
        try await iterator.next()
    }
}

@MainActor
@Observable
final class AudioPlayerService {
    let audioEngine: AudioEngine
    let equalizerService: EqualizerService
    private let sourceManager: SourceManager?
    private let library: MusicLibrary?

    private(set) var currentSong: Song?
    private(set) var isPlaying = false
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var isLoading = false

    var queue: [Song] = []
    var currentIndex: Int = 0
    var shuffleEnabled = false
    var repeatMode: RepeatMode = .off

    private var displayLink: Timer?
    private let nativeDecoder = NativeAudioDecoder()
    private let assetReaderDecoder = AssetReaderDecoder()
    private var decodingTask: Task<Void, Never>?
    private var crossfadeDecodingTask: Task<Void, Never>?
    private var crossfadeTimer: Timer?
    private var crossfadeTriggered = false
    private var playID: UUID?

    let playbackSettings: PlaybackSettingsStore

    init(sourceManager: SourceManager? = nil, library: MusicLibrary? = nil, playbackSettings: PlaybackSettingsStore = PlaybackSettingsStore()) {
        self.sourceManager = sourceManager
        self.library = library
        self.playbackSettings = playbackSettings
        audioEngine = AudioEngine()
        equalizerService = EqualizerService(audioEngine: audioEngine)
        setupRemoteCommands()
        setupAudioSessionCallbacks()
    }

    private func setupAudioSessionCallbacks() {
        let manager = AudioSessionManager.shared

        manager.onInterruptionBegan = { [weak self] in
            guard let self, self.isPlaying else { return }
            // Sync UI to paused state — the engine was already stopped by the system
            self.isPlaying = false
            self.stopTimeUpdater()
            self.updateNowPlayingInfo()
            self.updatePlaybackState()
        }

        manager.onInterruptionEndedShouldResume = { [weak self] in
            guard let self, !self.isPlaying, self.currentSong != nil else { return }
            self.resume()
        }

        manager.onConfigurationChange = { [weak self] in
            guard let self, self.isPlaying else { return }
            // Engine was stopped due to config change — restart it
            self.audioEngine.restartIfNeeded()
        }
    }

    // MARK: - Playback Control

    func play(song: Song) async {
        // Invalidate any pending operations immediately
        let id = UUID()
        playID = id
        print("▶️ play(song: \(song.title)) playID=\(id.uuidString.prefix(8))")

        // Stop current playback
        decodingTask?.cancel()
        decodingTask = nil
        crossfadeDecodingTask?.cancel()
        crossfadeDecodingTask = nil
        audioEngine.stopPlayback()
        audioEngine.stopCrossfadeNode()
        stopTimeUpdater()

        // Show new song in UI immediately (before download)
        currentSong = song
        duration = song.duration
        isLoading = true
        isPlaying = false
        print("▶️ currentSong set to: \(song.title)")

        do {
            let url = try await resolvedURL(for: song)
            // Check if another play was initiated while downloading
            guard playID == id else { return }
            await playFromURL(song: song, url: url, playID: id)
        } catch {
            guard playID == id else { return }
            print("Playback URL resolution error: \(error)")
            isLoading = false
            await next()
        }
    }

    func play(song: Song, from url: URL) async {
        let id = UUID()
        playID = id
        decodingTask?.cancel()
        decodingTask = nil
        audioEngine.stopPlayback()
        stopTimeUpdater()
        await playFromURL(song: song, url: url, playID: id)
    }

    private func playFromURL(song: Song, url: URL, playID id: UUID) async {
        print("▶️ playFromURL(song: \(song.title)) playID=\(id.uuidString.prefix(8))")
        currentSong = song
        duration = song.duration
        isLoading = true
        isPlaying = false
        audioEngine.sampleTimeOffset = 0
        crossfadeTriggered = false

        let isRemoteURL = url.scheme == "http" || url.scheme == "https"

        guard isRemoteURL || nativeDecoder.canDecode(url: url) else {
            print("Unsupported format: \(url.pathExtension)")
            isLoading = false
            if currentIndex < queue.count - 1 { await next() }
            return
        }

        do {
            try audioEngine.setUp()
            guard let outputFormat = audioEngine.outputFormat else {
                throw AudioDecoderError.decodingFailed("Audio engine not ready")
            }

            try audioEngine.start()

            // Reset volume immediately; apply ReplayGain asynchronously after playback starts
            audioEngine.resetPlayerVolume()

            // Remote URLs must use AVAssetReader (AVAudioFile requires local files)
            if isRemoteURL {
                print("▶️ Using streaming decoder for remote URL")
                await playWithFallbackDecoder(song: song, url: url, outputFormat: outputFormat, playID: id)
                return
            }

            // Try native decoder for local files
            let stream = nativeDecoder.decode(from: url, outputFormat: outputFormat)
            let iteratorBox = BufferIteratorBox(stream.makeAsyncIterator())

            // Await first buffer — ensures we have audio data before calling play()
            let firstBuffer: AVAudioPCMBuffer
            do {
                guard let buffer = try await iteratorBox.next() else {
                    // Empty stream — skip to next
                    isLoading = false
                    if currentIndex < queue.count - 1 { await next() }
                    return
                }
                guard playID == id else { return }
                firstBuffer = buffer
            } catch {
                // Native decode failed on first buffer — try fallback decoder
                guard !Task.isCancelled, playID == id else { return }
                print("⚠️ Native decode failed for '\(song.title)': \(error.localizedDescription)")
                await playWithFallbackDecoder(song: song, url: url, outputFormat: outputFormat, playID: id)
                return
            }

            // Schedule first buffer BEFORE play — playerNode has data ready
            audioEngine.scheduleBuffer(firstBuffer)
            audioEngine.play()

            // Fetch duration asynchronously if not already known
            if duration <= 0 {
                Task {
                    if let info = try? await nativeDecoder.fileInfo(for: url) {
                        guard self.playID == id else { return }
                        self.duration = info.duration
                        self.updateNowPlayingInfo()
                    }
                }
            }

            // NOW transition state — audio is actually playing
            isPlaying = true
            isLoading = false
            library?.recordPlayback(of: song.id)
            startTimeUpdater()
            updateNowPlayingInfo()
            updateNowPlayingArtworkIfNeeded()
            updatePlaybackState()

            // Apply ReplayGain in background (don't block playback start)
            let settings = playbackSettings.snapshot()
            if settings.replayGainEnabled {
                Task { [id] in
                    await self.applyReplayGain(for: url, mode: settings.replayGainMode)
                    guard self.playID == id else { return }
                }
            }

            // Background-cache file for offline playback
            sourceManager?.cacheInBackground(song: song)

            // Decode remaining buffers in background task (hold-last for completion callback)
            decodingTask = Task { [id, iteratorBox] in
                var lastBuffer: AVAudioPCMBuffer?

                do {
                    while let buffer = try await iteratorBox.next() {
                        guard !Task.isCancelled, self.playID == id else { return }

                        if let prev = lastBuffer {
                            self.audioEngine.scheduleBuffer(prev)
                        }
                        lastBuffer = buffer
                    }
                } catch {
                    if !Task.isCancelled {
                        print("⚠️ Decode error mid-stream for '\(song.title)': \(error.localizedDescription)")
                    }
                }

                // Schedule the final buffer with track-end detection
                if let finalBuffer = lastBuffer {
                    guard !Task.isCancelled, self.playID == id else { return }
                    self.scheduleLastBuffer(finalBuffer, playID: id)
                }
            }
        } catch {
            print("⚠️ Playback error for '\(song.title)': \(error.localizedDescription)")
            isLoading = false
            // Auto skip to next on decode failure
            if currentIndex < queue.count - 1 {
                await next()
            }
        }
    }

    /// Fallback playback using AVAssetReader when native decoder fails.
    private func playWithFallbackDecoder(song: Song, url: URL, outputFormat: AVAudioFormat, playID id: UUID) async {
        guard assetReaderDecoder.canDecode(url: url) else {
            print("⚠️ No decoder available for '\(song.title)'")
            isLoading = false
            if currentIndex < queue.count - 1 { await next() }
            return
        }

        print("↳ Retrying '\(song.title)' with AVAssetReader fallback...")

        let fallbackStream = assetReaderDecoder.decode(from: url, outputFormat: outputFormat)
        let iteratorBox = BufferIteratorBox(fallbackStream.makeAsyncIterator())

        do {
            guard let firstBuffer = try await iteratorBox.next() else {
                isLoading = false
                if currentIndex < queue.count - 1 { await next() }
                return
            }
            guard playID == id else { return }

            audioEngine.scheduleBuffer(firstBuffer)
            audioEngine.play()

            // Fetch duration asynchronously
            if duration <= 0 {
                Task {
                    if let info = await self.assetReaderDecoder.fileInfo(for: url) {
                        guard self.playID == id else { return }
                        self.duration = info.duration
                        self.updateNowPlayingInfo()
                    }
                }
            }

            // Transition state after audio starts
            isPlaying = true
            isLoading = false
            library?.recordPlayback(of: song.id)
            startTimeUpdater()
            updateNowPlayingInfo()
            updateNowPlayingArtworkIfNeeded()
            updatePlaybackState()

            // Apply ReplayGain in background (don't block playback start)
            let settings = playbackSettings.snapshot()
            if settings.replayGainEnabled, url.isFileURL {
                Task { [id] in
                    await self.applyReplayGain(for: url, mode: settings.replayGainMode)
                    guard self.playID == id else { return }
                }
            }

            // Background-cache file for offline playback
            sourceManager?.cacheInBackground(song: song)

            // Decode remaining buffers with track-end detection
            decodingTask = Task { [id, iteratorBox] in
                var lastBuffer: AVAudioPCMBuffer?

                do {
                    while let buffer = try await iteratorBox.next() {
                        guard !Task.isCancelled, self.playID == id else { return }

                        if let prev = lastBuffer {
                            self.audioEngine.scheduleBuffer(prev)
                        }
                        lastBuffer = buffer
                    }
                } catch {
                    if !Task.isCancelled {
                        print("⚠️ AssetReader fallback decode error: \(error.localizedDescription)")
                    }
                }

                if let finalBuffer = lastBuffer {
                    guard !Task.isCancelled, self.playID == id else { return }
                    self.scheduleLastBuffer(finalBuffer, playID: id)
                }
            }
        } catch {
            print("⚠️ AssetReader fallback also failed: \(error.localizedDescription)")
            isLoading = false
            if currentIndex < queue.count - 1 { await next() }
        }
    }

    /// Schedule the final buffer of a track with the appropriate completion callback
    /// for track-end detection, respecting gapless and crossfade settings.
    private func scheduleLastBuffer(_ buffer: AVAudioPCMBuffer, playID id: UUID) {
        let settings = playbackSettings.snapshot()

        if false && settings.gaplessEnabled && !settings.crossfadeEnabled {
            // Gapless: DISABLED — causes currentSong to show wrong track
            // TODO: fix gapless to defer currentSong update until buffer actually plays
            audioEngine.scheduleBuffer(buffer)
            Task { await self.gaplessPreloadNext(id: id) }
        } else {
            // Standard and crossfade modes both use completion callback
            audioEngine.scheduleBuffer(
                buffer,
                completionCallbackType: .dataPlayedBack
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.playID == id else { return }
                    // In crossfade mode, only handle track end if crossfade wasn't triggered
                    if settings.crossfadeEnabled && self.crossfadeTriggered { return }
                    await self.handleTrackEnd()
                }
            }
        }
    }

    func pause() {
        audioEngine.pause()
        isPlaying = false
        stopTimeUpdater()
        updateNowPlayingInfo()
        updatePlaybackState()
    }

    func resume() {
        audioEngine.resume()
        isPlaying = true
        startTimeUpdater()
        updateNowPlayingInfo()
        updatePlaybackState()
    }

    func togglePlayPause() {
        if isPlaying { pause() } else { resume() }
    }

    func stop() {
        decodingTask?.cancel()
        decodingTask = nil
        crossfadeDecodingTask?.cancel()
        crossfadeDecodingTask = nil
        crossfadeTimer?.invalidate()
        crossfadeTimer = nil
        crossfadeTriggered = false
        audioEngine.stopPlayback()
        audioEngine.stopCrossfadeNode()
        audioEngine.resetPlayerVolume()
        isPlaying = false
        currentTime = 0
        stopTimeUpdater()
    }

    func next() async {
        guard !queue.isEmpty else { return }
        if shuffleEnabled {
            currentIndex = Int.random(in: 0..<queue.count)
        } else {
            currentIndex = (currentIndex + 1) % queue.count
        }
        await play(song: queue[currentIndex])
    }

    func previous() async {
        guard !queue.isEmpty else { return }
        if currentTime > 3 {
            seek(to: 0)
            return
        }
        currentIndex = currentIndex > 0 ? currentIndex - 1 : queue.count - 1
        await play(song: queue[currentIndex])
    }

    private var seekTimeOffset: TimeInterval = 0

    func seek(to time: TimeInterval) {
        currentTime = time
        updateNowPlayingInfo()

        guard let song = currentSong else { return }
        let savedDuration = duration
        let wasPlaying = isPlaying

        // Invalidate old playID BEFORE stopPlayback() so any pending completion
        // callbacks (triggered by AVAudioPlayerNode.stop()) will fail
        // their guard check and won't trigger handleTrackEnd() → next().
        let id = UUID()
        playID = id

        // Stop only the playerNode, not the full pipeline — preserve Live Activity,
        // currentSong, and other state that stop() would tear down.
        decodingTask?.cancel()
        decodingTask = nil
        crossfadeDecodingTask?.cancel()
        crossfadeDecodingTask = nil
        audioEngine.stopPlayback()
        stopTimeUpdater()

        // Restore state that stopPlayback clears
        currentSong = song
        currentTime = time
        duration = savedDuration

        Task {
            do {
                let url = try await resolvedURL(for: song)
                guard playID == id else { return }
                try audioEngine.setUp()
                guard let outputFormat = audioEngine.outputFormat else { return }
                try audioEngine.start()

                let settings = playbackSettings.snapshot()
                if settings.replayGainEnabled {
                    await applyReplayGain(for: url, mode: settings.replayGainMode)
                }

                let stream = nativeDecoder.decode(from: url, outputFormat: outputFormat)
                let seekSamples = Int64(time * outputFormat.sampleRate)
                var samplesSkipped: Int64 = 0

                // Set sample time offset so currentTime calculation accounts for seek position
                audioEngine.sampleTimeOffset = -seekSamples

                // Skip buffers until seek position, then schedule first playable buffer before play()
                let iteratorBox = BufferIteratorBox(stream.makeAsyncIterator())
                var firstPlayableBuffer: AVAudioPCMBuffer?

                while let buffer = try await iteratorBox.next() {
                    guard playID == id else { return }
                    let bufferSamples = Int64(buffer.frameLength)
                    if samplesSkipped + bufferSamples <= seekSamples {
                        samplesSkipped += bufferSamples
                        continue
                    }
                    firstPlayableBuffer = buffer
                    break
                }

                guard let firstBuffer = firstPlayableBuffer else { return }
                guard playID == id else { return }

                audioEngine.scheduleBuffer(firstBuffer)
                if wasPlaying { audioEngine.play() }

                if wasPlaying {
                    isPlaying = true
                    startTimeUpdater()
                }

                // Decode remaining buffers with track-end detection
                decodingTask = Task { [id, iteratorBox] in
                    var lastBuffer: AVAudioPCMBuffer?

                    do {
                        while let buffer = try await iteratorBox.next() {
                            guard !Task.isCancelled, self.playID == id else { return }

                            if let prev = lastBuffer {
                                self.audioEngine.scheduleBuffer(prev)
                            }
                            lastBuffer = buffer
                        }
                    } catch {
                        if !Task.isCancelled { print("Seek decode error: \(error)") }
                    }

                    if let finalBuffer = lastBuffer {
                        guard !Task.isCancelled, self.playID == id else { return }
                        self.scheduleLastBuffer(finalBuffer, playID: id)
                    }
                }
            } catch {
                print("Seek error: \(error)")
            }
        }
    }

    func setQueue(_ songs: [Song], startAt index: Int = 0) {
        queue = songs
        currentIndex = min(index, songs.count - 1)
    }

    func syncSongMetadata(_ updatedSong: Song) {
        if currentSong?.id == updatedSong.id {
            currentSong = updatedSong
            updateNowPlayingInfo()
            updatePlaybackState()
        }
        if let queueIndex = queue.firstIndex(where: { $0.id == updatedSong.id }) {
            queue[queueIndex] = updatedSong
        }
    }

    // MARK: - Gapless Playback

    /// After current track's buffers are all scheduled, preload ONE next track's
    /// buffers into the SAME playerNode. Uses a completion callback on the last
    /// buffer to chain the next preload — no recursion.
    private func gaplessPreloadNext(id: UUID) async {
        guard self.playID == id else {
            print("🔄 gaplessPreload: ABORTED (playID mismatch)")
            return
        }
        guard let nextSong = nextSongInQueue() else {
            // No next song — use completion callback to detect track end
            scheduleEndDetection(id: id)
            return
        }

        // For repeat-one, don't gapless-chain (use normal replay via callback)
        if repeatMode == .one {
            scheduleEndDetection(id: id)
            return
        }

        do {
            let nextURL = try await resolvedURL(for: nextSong)
            guard nativeDecoder.canDecode(url: nextURL),
                  let outputFormat = audioEngine.outputFormat else {
                scheduleEndDetection(id: id)
                return
            }

            // Mark the sample boundary for time tracking
            audioEngine.markTrackBoundary()

            // Update state for the new track
            advanceToNextIndex()
            print("🔄 gaplessPreload: currentSong → \(nextSong.title)")
            currentSong = nextSong
            duration = nextSong.duration
            currentTime = 0
            crossfadeTriggered = false
            library?.recordPlayback(of: nextSong.id)

            // Apply ReplayGain for next track
            let settings = playbackSettings.snapshot()
            if settings.replayGainEnabled {
                await applyReplayGain(for: nextURL, mode: settings.replayGainMode)
            }

            // Decode and schedule next track's buffers (only this one track)
            let stream = nativeDecoder.decode(from: nextURL, outputFormat: outputFormat)
            var isFirst = true
            var lastBuffer: AVAudioPCMBuffer?

            for try await buffer in stream {
                guard !Task.isCancelled, self.playID == id else { return }

                if let prev = lastBuffer {
                    audioEngine.scheduleBuffer(prev)
                }
                lastBuffer = buffer

                if isFirst {
                    isFirst = false
                    Task {
                        if let info = try? await nativeDecoder.fileInfo(for: nextURL) {
                            self.duration = info.duration
                        }
                    }
                    updateNowPlayingInfo()
                    updatePlaybackState()
                }
            }

            // Schedule the last buffer with completion → chain next preload
            if let finalBuffer = lastBuffer {
                guard !Task.isCancelled, self.playID == id else { return }
                audioEngine.scheduleBuffer(
                    finalBuffer,
                    completionCallbackType: .dataPlayedBack
                ) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        guard let self, self.playID == id else { return }
                        // Chain: preload the NEXT track when this one finishes playing
                        await self.gaplessPreloadNext(id: id)
                    }
                }
            }
        } catch {
            print("Gapless preload error: \(error)")
            scheduleEndDetection(id: id)
        }
    }

    /// Schedule a silent buffer with completion callback to detect when all audio finishes.
    private func scheduleEndDetection(id: UUID) {
        guard let silence = createSilentBuffer(frameCount: 1) else { return }
        audioEngine.scheduleBuffer(
            silence,
            completionCallbackType: .dataPlayedBack
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.playID == id else { return }
                await self.handleTrackEnd()
            }
        }
    }

    // MARK: - Crossfade

    private func checkCrossfade() {
        let settings = playbackSettings.snapshot()
        guard settings.crossfadeEnabled, !crossfadeTriggered else { return }
        guard duration > 0, currentTime >= duration - settings.crossfadeDuration else { return }
        guard nextSongInQueue() != nil else { return }

        crossfadeTriggered = true
        Task { await startCrossfade(duration: settings.crossfadeDuration) }
    }

    private func startCrossfade(duration crossfadeDuration: Double) async {
        guard let nextSong = nextSongInQueue() else { return }

        do {
            let nextURL = try await resolvedURL(for: nextSong)
            guard nativeDecoder.canDecode(url: nextURL),
                  let outputFormat = audioEngine.outputFormat else { return }

            // Apply ReplayGain for next track on crossfade node
            let settings = playbackSettings.snapshot()
            // Note: ReplayGain for crossfade node would need per-node volume tracking
            // For now, apply after swap

            // Decode into crossfade node — schedule first buffer before play
            let stream = nativeDecoder.decode(from: nextURL, outputFormat: outputFormat)
            let iteratorBox = BufferIteratorBox(stream.makeAsyncIterator())

            guard let firstBuffer = try await iteratorBox.next() else { return }
            audioEngine.scheduleCrossfadeBuffer(firstBuffer)
            audioEngine.playCrossfadeNode()

            crossfadeDecodingTask = Task { [iteratorBox] in
                do {
                    while let buffer = try await iteratorBox.next() {
                        guard !Task.isCancelled else { return }
                        self.audioEngine.scheduleCrossfadeBuffer(buffer)
                    }
                } catch {
                    if !Task.isCancelled { print("Crossfade decode error: \(error)") }
                }
            }

            // Start volume ramp using MainActor-isolated timer
            await MainActor.run {
                startCrossfadeRamp(
                    duration: crossfadeDuration,
                    nextSong: nextSong,
                    nextURL: nextURL
                )
            }
        } catch {
            print("Crossfade start error: \(error)")
            crossfadeTriggered = false
        }
    }

    private func startCrossfadeRamp(duration: Double, nextSong: Song, nextURL: URL) {
        let totalSteps = max(1, Int(duration / 0.05))
        let stepCounter = StepCounter()
        let rampPlayID = playID

        crossfadeTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.playID == rampPlayID else {
                    self?.crossfadeTimer?.invalidate()
                    self?.crossfadeTimer = nil
                    return
                }
                stepCounter.value += 1
                let progress = Float(stepCounter.value) / Float(totalSteps)

                if progress >= 1.0 {
                    self.crossfadeTimer?.invalidate()
                    self.crossfadeTimer = nil
                    self.completeCrossfade(nextSong: nextSong, nextURL: nextURL)
                } else {
                    self.audioEngine.setCrossfadeVolumes(
                        primary: 1.0 - progress,
                        crossfade: progress
                    )
                }
            }
        }
    }

    private func completeCrossfade(nextSong: Song, nextURL: URL) {
        // Stop old decoding
        decodingTask?.cancel()
        decodingTask = nil

        // Swap nodes
        audioEngine.swapPlayerNodes()
        audioEngine.sampleTimeOffset = 0

        // Transfer crossfade decoding task to main
        decodingTask = crossfadeDecodingTask
        crossfadeDecodingTask = nil

        // Update state — also update playID so this becomes the authoritative session
        let newID = UUID()
        playID = newID
        advanceToNextIndex()
        print("🔄 completeCrossfade: currentSong → \(nextSong.title)")
        currentSong = nextSong
        currentTime = 0
        crossfadeTriggered = false
        library?.recordPlayback(of: nextSong.id)

        // Apply ReplayGain (now on the swapped primary node)
        let settings = playbackSettings.snapshot()
        if settings.replayGainEnabled {
            Task { await applyReplayGain(for: nextURL, mode: settings.replayGainMode) }
        }

        Task {
            if let info = try? await nativeDecoder.fileInfo(for: nextURL) {
                self.duration = info.duration
            }
        }

        updateNowPlayingInfo()
        updatePlaybackState()
    }

    // MARK: - ReplayGain

    private func applyReplayGain(for url: URL, mode: ReplayGainMode) async {
        let metadata = await FileMetadataReader.read(from: url)

        let gain: Double?
        let peak: Double?

        switch mode {
        case .track:
            gain = metadata.replayGainTrackGain
            peak = metadata.replayGainTrackPeak
        case .album:
            gain = metadata.replayGainAlbumGain ?? metadata.replayGainTrackGain
            peak = metadata.replayGainAlbumPeak ?? metadata.replayGainTrackPeak
        }

        audioEngine.applyReplayGain(gain: gain, peak: peak)
    }

    // MARK: - Time Updates

    private func startTimeUpdater() {
        stopTimeUpdater()
        displayLink = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let time = self.audioEngine.currentTime {
                    self.currentTime = time
                }
                // Check if crossfade should start
                self.checkCrossfade()
            }
        }
    }

    private func stopTimeUpdater() {
        displayLink?.invalidate()
        displayLink = nil
    }

    // MARK: - Track End

    private func handleTrackEnd() async {
        print("⏭️ handleTrackEnd() currentSong=\(currentSong?.title ?? "nil") playID=\(playID?.uuidString.prefix(8) ?? "nil")")
        switch repeatMode {
        case .one:
            if let song = currentSong { await play(song: song) }
        case .all:
            await next()
        case .off:
            if currentIndex < queue.count - 1 {
                await next()
            } else {
                stop()
            }
        }
    }

    // MARK: - Helpers

    private func nextSongInQueue() -> Song? {
        guard !queue.isEmpty else { return nil }

        if repeatMode == .one { return currentSong }

        let nextIndex: Int
        if shuffleEnabled {
            nextIndex = Int.random(in: 0..<queue.count)
        } else {
            nextIndex = currentIndex + 1
        }

        if nextIndex < queue.count {
            return queue[nextIndex]
        } else if repeatMode == .all {
            return queue[0]
        }
        return nil
    }

    private func advanceToNextIndex() {
        if shuffleEnabled {
            currentIndex = Int.random(in: 0..<queue.count)
        } else {
            currentIndex = (currentIndex + 1) % queue.count
        }
    }

    private func createSilentBuffer(frameCount: AVAudioFrameCount) -> AVAudioPCMBuffer? {
        guard let format = audioEngine.outputFormat,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return nil
        }
        buffer.frameLength = frameCount
        // Buffer is zero-initialized by default — silence
        return buffer
    }

    // MARK: - URL Resolution

    private func resolvedURL(for song: Song) async throws -> URL {
        if let sourceManager {
            do {
                return try await sourceManager.resolveURL(for: song)
            } catch {
                if song.filePath.hasPrefix("/") {
                    return URL(fileURLWithPath: song.filePath)
                }
                throw error
            }
        }
        if let remoteURL = URL(string: song.filePath), remoteURL.scheme != nil {
            return remoteURL
        }
        return URL(fileURLWithPath: song.filePath)
    }

    // MARK: - Now Playing Info

    /// Tracks which cover we last loaded to avoid redundant disk reads
    private var lastArtworkFileName: String?

    private func updateNowPlayingInfo() {
        // Create fresh info but preserve existing artwork
        var info = [String: Any]()
        info[MPMediaItemPropertyTitle] = currentSong?.title ?? ""
        info[MPMediaItemPropertyArtist] = currentSong?.artistName ?? ""
        info[MPMediaItemPropertyAlbumTitle] = currentSong?.albumTitle ?? ""
        info[MPMediaItemPropertyPlaybackDuration] = duration
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0

        // Carry over existing artwork (set separately by updateNowPlayingArtworkIfNeeded)
        if let existingArtwork = MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork] {
            info[MPMediaItemPropertyArtwork] = existingArtwork
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// Call ONLY when song changes — loads cover art and sets MPMediaItemPropertyArtwork
    private func updateNowPlayingArtworkIfNeeded() {
        let coverFileName = currentSong?.coverArtFileName
        guard coverFileName != lastArtworkFileName else { return }
        lastArtworkFileName = coverFileName

        guard let coverFileName, !coverFileName.isEmpty else { return }

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
                .appendingPathComponent("primuse_covers")
            let artworkDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent("Primuse/MetadataAssets/artwork")

            var image: UIImage?
            let primaryURL = cacheDir.appendingPathComponent(coverFileName)
            if let data = try? Data(contentsOf: primaryURL) {
                image = UIImage(data: data)
            }
            if image == nil {
                let fallbackURL = artworkDir.appendingPathComponent(coverFileName)
                if let data = try? Data(contentsOf: fallbackURL) {
                    image = UIImage(data: data)
                }
            }

            guard let loadedImage = image else { return }

            // Create artwork outside MainActor so the requestHandler closure
            // doesn't inherit @MainActor isolation (MediaPlayer calls it on a background queue).
            let artwork = Self.makeArtwork(from: loadedImage)

            await MainActor.run {
                var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
                info[MPMediaItemPropertyArtwork] = artwork
                MPNowPlayingInfoCenter.default().nowPlayingInfo = info
            }
        }
    }

    func updateNowPlayingArtwork(_ image: UIImage) {
        lastArtworkFileName = currentSong?.coverArtFileName
        let artwork = Self.makeArtwork(from: image)
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPMediaItemPropertyArtwork] = artwork
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// Creates MPMediaItemArtwork with a non-isolated requestHandler closure.
    /// Must be nonisolated so the closure doesn't inherit @MainActor isolation —
    /// MediaPlayer calls the handler on a background dispatch queue.
    nonisolated private static func makeArtwork(from image: UIImage) -> MPMediaItemArtwork {
        nonisolated(unsafe) let safeImage = image
        return MPMediaItemArtwork(boundsSize: image.size) { _ in safeImage }
    }

    // MARK: - Remote Commands

    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in self?.resume(); return .success }
        center.pauseCommand.addTarget { [weak self] _ in self?.pause(); return .success }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in self?.togglePlayPause(); return .success }
        center.nextTrackCommand.addTarget { [weak self] _ in
            Task { await self?.next() }; return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            Task { await self?.previous() }; return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.seek(to: event.positionTime); return .success
        }
    }

    // MARK: - Shared Playback State

    private func updatePlaybackState() {
        let state = PlaybackState(
            currentSongID: currentSong?.id,
            songTitle: currentSong?.title,
            artistName: currentSong?.artistName,
            albumTitle: currentSong?.albumTitle,
            isPlaying: isPlaying,
            currentTime: currentTime,
            duration: duration,
            queueSongIDs: queue.map(\.id)
        )
        state.save()
    }
}
