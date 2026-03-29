import AVFoundation
import Foundation
import MediaPlayer
import PrimuseKit

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
        audioEngine.sampleTimeOffset = 0
        crossfadeTriggered = false

        guard nativeDecoder.canDecode(url: url) else {
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

            // Apply ReplayGain
            let settings = playbackSettings.snapshot()
            if settings.replayGainEnabled {
                await applyReplayGain(for: url, mode: settings.replayGainMode)
            } else {
                audioEngine.resetPlayerVolume()
            }

            // Try native decoder first; if it fails on first buffer, fallback to AVAssetReader
            let stream = nativeDecoder.decode(from: url, outputFormat: outputFormat)

            decodingTask = Task { [id] in
                do {
                    var bufferCount = 0
                    var lastBuffer: AVAudioPCMBuffer?

                    for try await buffer in stream {
                        guard !Task.isCancelled, self.playID == id else { return }

                        // Schedule previous buffer (not the last one yet)
                        if let prev = lastBuffer {
                            audioEngine.scheduleBuffer(prev)
                        }
                        lastBuffer = buffer
                        bufferCount += 1

                        if bufferCount == 1 {
                            audioEngine.play()
                            // Duration from scan is already set via song.duration
                            // Only fetch if scan didn't extract it
                            if self.duration <= 0 {
                                Task {
                                    if let info = try? await nativeDecoder.fileInfo(for: url) {
                                        self.duration = info.duration
                                        self.updateNowPlayingInfo()
                                    }
                                }
                            }
                        }
                    }

                    // Schedule the LAST buffer with completion callback for track-end detection
                    if let finalBuffer = lastBuffer {
                        guard !Task.isCancelled, self.playID == id else { return }

                        let settings = playbackSettings.snapshot()

                        if false && settings.gaplessEnabled && !settings.crossfadeEnabled {
                            // Gapless: DISABLED — causes currentSong to show wrong track
                            // TODO: fix gapless to defer currentSong update until buffer actually plays
                            audioEngine.scheduleBuffer(finalBuffer)
                            await self.gaplessPreloadNext(id: id)
                        } else if !settings.crossfadeEnabled {
                            // No gapless, no crossfade: use completion callback
                            audioEngine.scheduleBuffer(
                                finalBuffer,
                                completionCallbackType: .dataPlayedBack
                            ) { [weak self] _ in
                                Task { @MainActor [weak self] in
                                    guard let self, self.playID == id else { return }
                                    await self.handleTrackEnd()
                                }
                            }
                        } else {
                            // Crossfade mode: just schedule, crossfade is triggered by time updater
                            audioEngine.scheduleBuffer(
                                finalBuffer,
                                completionCallbackType: .dataPlayedBack
                            ) { [weak self] _ in
                                Task { @MainActor [weak self] in
                                    guard let self, self.playID == id else { return }
                                    // Only handle track end if crossfade wasn't triggered
                                    if !self.crossfadeTriggered {
                                        await self.handleTrackEnd()
                                    }
                                }
                            }
                        }
                    }
                } catch {
                    if !Task.isCancelled {
                        print("⚠️ Native decode failed for '\(song.title)': \(error.localizedDescription)")
                        // Fallback: try AVAssetReader (handles more MP3 variants)
                        if self.assetReaderDecoder.canDecode(url: url) {
                            print("↳ Retrying with AVAssetReader fallback...")
                            let fallbackStream = self.assetReaderDecoder.decode(from: url, outputFormat: outputFormat)
                            do {
                                var started = false
                                for try await buffer in fallbackStream {
                                    guard !Task.isCancelled, self.playID == id else { return }
                                    self.audioEngine.scheduleBuffer(buffer)
                                    if !started {
                                        self.audioEngine.play()
                                        started = true
                                        // Get duration from AssetReader
                                        if self.duration <= 0 {
                                            Task {
                                                if let info = await self.assetReaderDecoder.fileInfo(for: url) {
                                                    self.duration = info.duration
                                                    self.updateNowPlayingInfo()
                                                }
                                            }
                                        }
                                    }
                                }
                            } catch {
                                if !Task.isCancelled {
                                    print("⚠️ AssetReader fallback also failed: \(error.localizedDescription)")
                                }
                            }
                        }
                    }
                }
            }

            isPlaying = true
            library?.recordPlayback(of: song.id)
            isLoading = false
            startTimeUpdater()
            updateNowPlayingInfo()
            updatePlaybackState()
        } catch {
            print("⚠️ Playback error for '\(song.title)': \(error.localizedDescription)")
            isLoading = false
            // Auto skip to next on decode failure
            if currentIndex < queue.count - 1 {
                await next()
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

        Task {
            let wasPlaying = isPlaying
            stop()
            currentSong = song
            currentTime = time
            duration = savedDuration
            seekTimeOffset = time

            do {
                let url = try await resolvedURL(for: song)
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
                let id = UUID()
                playID = id

                // Set sample time offset so currentTime calculation accounts for seek position
                audioEngine.sampleTimeOffset = -seekSamples

                decodingTask = Task { [id] in
                    do {
                        var started = false
                        for try await buffer in stream {
                            guard !Task.isCancelled, self.playID == id else { return }

                            let bufferSamples = Int64(buffer.frameLength)
                            if samplesSkipped + bufferSamples <= seekSamples {
                                samplesSkipped += bufferSamples
                                continue
                            }

                            audioEngine.scheduleBuffer(buffer)
                            if !started {
                                if wasPlaying { audioEngine.play() }
                                started = true
                            }
                        }
                    } catch {
                        if !Task.isCancelled { print("Seek decode error: \(error)") }
                    }
                }

                if wasPlaying {
                    isPlaying = true
                    startTimeUpdater()
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

            // Decode into crossfade node
            let stream = nativeDecoder.decode(from: nextURL, outputFormat: outputFormat)

            crossfadeDecodingTask = Task {
                do {
                    var started = false
                    for try await buffer in stream {
                        guard !Task.isCancelled else { return }
                        audioEngine.scheduleCrossfadeBuffer(buffer)

                        if !started {
                            audioEngine.playCrossfadeNode()
                            started = true
                        }
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
        var currentStep = 0
        let rampPlayID = playID

        crossfadeTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self, self.playID == rampPlayID else {
                self?.crossfadeTimer?.invalidate()
                self?.crossfadeTimer = nil
                return
            }
            currentStep += 1
            let progress = Float(currentStep) / Float(totalSteps)

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

    private func updateNowPlayingInfo() {
        var info = [String: Any]()
        info[MPMediaItemPropertyTitle] = currentSong?.title ?? ""
        info[MPMediaItemPropertyArtist] = currentSong?.artistName ?? ""
        info[MPMediaItemPropertyAlbumTitle] = currentSong?.albumTitle ?? ""
        info[MPMediaItemPropertyPlaybackDuration] = duration
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    func updateNowPlayingArtwork(_ image: UIImage) {
        let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPMediaItemPropertyArtwork] = artwork
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
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
