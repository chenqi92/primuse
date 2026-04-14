import AVFoundation
import CryptoKit
import Foundation
import MediaPlayer
import PrimuseKit
import UIKit
import WidgetKit

/// Mutable counter that can be captured by @Sendable closures (e.g. Timer callbacks wrapped in Task).
private final class StepCounter: @unchecked Sendable {
    var value = 0
}

/// Sendable wrapper for AsyncThrowingStream.Iterator to safely transfer across isolation boundaries.
///
/// **Safety contract:** The iterator is accessed sequentially — never concurrently:
/// 1. Created on MainActor in one of the `play*` methods.
/// 2. First buffer awaited on MainActor (still single-threaded).
/// 3. Ownership is then transferred exclusively to a single `decodingTask` via capture.
/// 4. No other code path calls `next()` on the same instance.
///
/// If this invariant changes (e.g. multiple consumers), replace `@unchecked Sendable`
/// with an actor wrapper or protect `iterator` with `os_unfair_lock`.
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
    let audioEffectsService: AudioEffectsService
    private let sourceManager: SourceManager?
    private let library: MusicLibrary?

    private(set) var currentSong: Song?
    private(set) var isPlaying = false
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var isLoading = false
    private(set) var lastPlaybackError: String?

    var queue: [Song] = []
    var currentIndex: Int = 0
    var shuffleEnabled = false {
        didSet { rebuildShuffleOrder() }
    }
    var repeatMode: RepeatMode = .off

    // MARK: - Shuffle Order
    private var shuffledIndices: [Int] = []
    private var shufflePosition: Int = 0

    // MARK: - Decoder Tracking (for seek)
    private enum DecoderKind { case native, streaming, assetReader }
    private var activeDecoderKind: DecoderKind = .native

    // MARK: - Sleep Timer
    private(set) var sleepTimerEndDate: Date?
    private var sleepTimerTask: Task<Void, Never>?
    var isSleepTimerActive: Bool { sleepTimerEndDate != nil }

    private var displayLink: Timer?
    private let nativeDecoder = NativeAudioDecoder()
    private let assetReaderDecoder = AssetReaderDecoder()
    private let streamingDecoder = StreamingDownloadDecoder()
    private var decodingTask: Task<Void, Never>?
    private var prefetchTask: Task<Void, Never>?
    private var crossfadeDecodingTask: Task<Void, Never>?
    private var crossfadeTimer: Timer?
    private var crossfadeTriggered = false
    private var playID: UUID?

    private var errorDismissTask: Task<Void, Never>?
    private var shouldResumeAfterInterruption = false
    private var needsPlaybackRecovery = false
    private var pendingRecoveryTime: TimeInterval = 0

    let playbackSettings: PlaybackSettingsStore

    init(sourceManager: SourceManager? = nil, library: MusicLibrary? = nil, playbackSettings: PlaybackSettingsStore = PlaybackSettingsStore()) {
        self.sourceManager = sourceManager
        self.library = library
        self.playbackSettings = playbackSettings
        audioEngine = AudioEngine()
        equalizerService = EqualizerService(audioEngine: audioEngine)
        audioEffectsService = AudioEffectsService(audioEngine: audioEngine, settingsStore: playbackSettings)

        // Defer heavy system registrations to avoid blocking first frame
        Task { @MainActor [weak self] in
            AudioSessionManager.shared.configureForPlayback()
            self?.setupRemoteCommands()
            self?.setupAudioSessionCallbacks()
        }
    }

    private func setupAudioSessionCallbacks() {
        let manager = AudioSessionManager.shared

        manager.onInterruptionBegan = { [weak self] in
            guard let self, self.currentSong != nil else { return }
            let wasPlaying = self.isPlaying
            self.syncPlaybackProgressFromEngine()
            self.pendingRecoveryTime = self.currentTime
            self.needsPlaybackRecovery = wasPlaying
            self.shouldResumeAfterInterruption = wasPlaying

            guard wasPlaying else { return }
            // Sync UI to paused state — the engine was already stopped by the system.
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
            guard let self, self.currentSong != nil else { return }
            let shouldAutoResume = self.isPlaying || self.shouldResumeAfterInterruption
            self.syncPlaybackProgressFromEngine()
            self.pendingRecoveryTime = self.currentTime
            self.needsPlaybackRecovery = self.needsPlaybackRecovery || shouldAutoResume

            guard shouldAutoResume else { return }
            // Engine was stopped due to config change — restart it if possible, and
            // rebuild the player pipeline on the next resume/play if buffers were lost.
            self.audioEngine.restartIfNeeded()
        }
    }

    private func clearPendingPlaybackRecovery() {
        shouldResumeAfterInterruption = false
        needsPlaybackRecovery = false
        pendingRecoveryTime = 0
    }

    private func syncPlaybackProgressFromEngine() {
        guard let engineTime = audioEngine.currentTime, engineTime.isFinite else { return }
        currentTime = max(0, engineTime)
    }

    private func showPlaybackError(_ message: String) {
        lastPlaybackError = message
        errorDismissTask?.cancel()
        errorDismissTask = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self.lastPlaybackError = nil
        }
    }

    // MARK: - Playback Control

    func play(song: Song, caller: String = #fileID, callerLine: Int = #line) async {
        // Invalidate any pending operations immediately
        let id = UUID()
        playID = id
        clearPendingPlaybackRecovery()
        let callerFile = (caller as NSString).lastPathComponent
        plog("▶️ play(song: \(song.title)) playID=\(id.uuidString.prefix(8)) FROM=\(callerFile):\(callerLine)")

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
        currentTime = 0
        duration = song.duration.sanitizedDuration
        isLoading = true
        isPlaying = false
        plog("▶️ currentSong set to: \(song.title)")

        do {
            let url = try await resolvedURL(for: song)
            // Check if another play was initiated while downloading
            guard playID == id else { return }
            await playFromURL(song: song, url: url, playID: id)
        } catch {
            guard playID == id else { return }
            plog("Playback URL resolution error: \(error)")
            showPlaybackError(String(localized: "playback_error_connection"))
            isLoading = false
            await next()
        }
    }

    func play(song: Song, from url: URL) async {
        let id = UUID()
        playID = id
        clearPendingPlaybackRecovery()
        decodingTask?.cancel()
        decodingTask = nil
        audioEngine.stopPlayback()
        stopTimeUpdater()
        await playFromURL(song: song, url: url, playID: id)
    }

    private func playFromURL(song: Song, url: URL, playID id: UUID) async {
        plog("▶️ playFromURL(song: \(song.title)) playID=\(id.uuidString.prefix(8))")
        plog("▶️   URL: \(url.absoluteString.prefix(120))")
        plog("▶️   scheme=\(url.scheme ?? "nil") isFileURL=\(url.isFileURL) ext=\(url.pathExtension) format=\(song.fileFormat) duration=\(song.duration)")
        currentSong = song
        duration = song.duration.sanitizedDuration
        isLoading = true
        isPlaying = false
        audioEngine.sampleTimeOffset = 0
        crossfadeTriggered = false
        activeDecoderKind = .native

        let isRemoteURL = url.scheme == "http" || url.scheme == "https"

        guard isRemoteURL || nativeDecoder.canDecode(url: url) else {
            plog("Unsupported format: \(url.pathExtension)")
            isLoading = false
            if currentIndex < queue.count - 1 { await next() }
            return
        }

        do {
            _ = AudioSessionManager.shared.activatePlaybackSession()
            try audioEngine.setUp()
            audioEffectsService.applySettings()
            guard let outputFormat = audioEngine.outputFormat else {
                throw AudioDecoderError.decodingFailed("Audio engine not ready")
            }

            try audioEngine.start()

            // Reset volume immediately; apply ReplayGain asynchronously after playback starts
            audioEngine.resetPlayerVolume()

            // Remote URLs: use StreamingDownloadDecoder (handles self-signed HTTPS via URLSession)
            if isRemoteURL {
                plog("▶️ Using StreamingDownloadDecoder for remote URL: \(url.scheme ?? "")://...")
                plog("▶️   outputFormat: sr=\(outputFormat.sampleRate) ch=\(outputFormat.channelCount)")
                let cacheURL = playbackSettings.audioCacheEnabled ? sourceManager?.cacheURL(for: song) : nil
                await playWithStreamingDownload(song: song, url: url, outputFormat: outputFormat, playID: id, cacheURL: cacheURL)
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
                plog("⚠️ Native decode failed for '\(song.title)': \(error.localizedDescription)")
                await playWithFallbackDecoder(song: song, url: url, outputFormat: outputFormat, playID: id)
                return
            }

            // Schedule first buffer BEFORE play — playerNode has data ready
            plog("▶️ NativeDecoder firstBuffer: frames=\(firstBuffer.frameLength) format=sr\(firstBuffer.format.sampleRate)/ch\(firstBuffer.format.channelCount)")
            plog("▶️ Engine state: outputFormat=sr\(outputFormat.sampleRate)/ch\(outputFormat.channelCount) mainVol=\(audioEngine.volume)")
            plog("▶️ Engine diagnostics: \(audioEngine.diagnosticInfo())")
            audioEngine.scheduleBuffer(firstBuffer)
            audioEngine.play()
            plog("▶️ After play(): \(audioEngine.diagnosticInfo())")

            // Fetch duration asynchronously if not already known
            if duration <= 0 {
                Task {
                    if let info = try? await nativeDecoder.fileInfo(for: url) {
                        guard self.playID == id else { return }
                        self.duration = info.duration.sanitizedDuration
                        self.updateNowPlayingInfo()
                    }
                }
            }

            // NOW transition state — audio is actually playing
            isPlaying = true
            isLoading = false
            clearPendingPlaybackRecovery()
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

            // Background-cache file for offline playback (if enabled)
            if playbackSettings.audioCacheEnabled {
                sourceManager?.cacheInBackground(song: song)
            }

            // Prefetch next song
            prefetchNextSong()

            // Decode remaining buffers in background task (hold-last for completion callback)
            decodingTask = Task { [id, iteratorBox] in
                var lastBuffer: AVAudioPCMBuffer?
                var scheduledCount = 0

                do {
                    while let buffer = try await iteratorBox.next() {
                        guard !Task.isCancelled, self.playID == id else { return }

                        if let prev = lastBuffer {
                            self.audioEngine.scheduleBuffer(prev)
                            scheduledCount += 1
                        }
                        lastBuffer = buffer
                    }
                } catch {
                    if !Task.isCancelled, self.playID == id {
                        plog("⚠️ Decode error mid-stream for '\(song.title)' (scheduled \(scheduledCount) buffers): \(error.localizedDescription)")
                        // Too few buffers → effectively no audio; stop and skip
                        if scheduledCount < 3 {
                            self.showPlaybackError(String(localized: "playback_error_decode"))
                            self.stop()
                            if self.currentIndex < self.queue.count - 1 {
                                await self.next()
                            }
                            return
                        }
                    }
                }

                // Schedule the final buffer with track-end detection
                if let finalBuffer = lastBuffer {
                    guard !Task.isCancelled, self.playID == id else { return }
                    self.scheduleLastBuffer(finalBuffer, playID: id)
                }
            }
        } catch {
            plog("⚠️ Playback error for '\(song.title)': \(error.localizedDescription)")
            showPlaybackError(String(localized: "playback_error_decode"))
            isLoading = false
            // Auto skip to next on decode failure
            if currentIndex < queue.count - 1 {
                await next()
            }
        }
    }

    /// Streaming playback using URLSession download + progressive decode.
    /// Handles self-signed HTTPS certificates that AVAssetReader cannot.
    private func playWithStreamingDownload(
        song: Song, url: URL, outputFormat: AVAudioFormat,
        playID id: UUID, cacheURL: URL?
    ) async {
        let stream = streamingDecoder.decode(from: url, outputFormat: outputFormat, cacheFileURL: cacheURL, fileExtension: song.fileFormat.rawValue)
        let iteratorBox = BufferIteratorBox(stream.makeAsyncIterator())

        do {
            guard let firstBuffer = try await iteratorBox.next() else {
                plog("⚠️ StreamingDownload: empty stream for '\(song.title)'")
                isLoading = false
                if currentIndex < queue.count - 1 { await next() }
                return
            }
            guard playID == id else { return }

            plog("🌊 StreamingDownload firstBuffer: frames=\(firstBuffer.frameLength) sr=\(firstBuffer.format.sampleRate)")
            plog("🌊 Engine diagnostics before play: \(audioEngine.diagnosticInfo())")
            activeDecoderKind = .streaming
            audioEngine.scheduleBuffer(firstBuffer)
            audioEngine.play()
            plog("🌊 Engine diagnostics after play: \(audioEngine.diagnosticInfo())")

            // Fetch duration asynchronously if needed
            if duration <= 0 {
                Task {
                    if let info = try? await self.nativeDecoder.fileInfo(for: url) {
                        guard self.playID == id else { return }
                        self.duration = info.duration.sanitizedDuration
                        self.updateNowPlayingInfo()
                    }
                }
            }

            // Transition state — audio is playing
            isPlaying = true
            isLoading = false
            clearPendingPlaybackRecovery()
            library?.recordPlayback(of: song.id)
            startTimeUpdater()
            updateNowPlayingInfo()
            updateNowPlayingArtworkIfNeeded()
            updatePlaybackState()

            // Prefetch next song while current one plays
            prefetchNextSong()

            // Decode remaining buffers
            decodingTask = Task { [id, iteratorBox] in
                var lastBuffer: AVAudioPCMBuffer?
                var scheduledCount = 0
                do {
                    while let buffer = try await iteratorBox.next() {
                        guard !Task.isCancelled, self.playID == id else { return }
                        if let prev = lastBuffer {
                            self.audioEngine.scheduleBuffer(prev)
                            scheduledCount += 1
                        }
                        lastBuffer = buffer
                    }
                } catch {
                    if !Task.isCancelled, self.playID == id {
                        plog("⚠️ StreamingDownload decode error (scheduled \(scheduledCount) buffers): \(error.localizedDescription)")
                        if scheduledCount < 3 {
                            self.showPlaybackError(String(localized: "playback_error_decode"))
                            self.stop()
                            if self.currentIndex < self.queue.count - 1 {
                                await self.next()
                            }
                            return
                        }
                    }
                }
                if let finalBuffer = lastBuffer {
                    guard !Task.isCancelled, self.playID == id else { return }
                    self.scheduleLastBuffer(finalBuffer, playID: id)
                }
            }
        } catch {
            plog("⚠️ StreamingDownload failed for '\(song.title)': \(error.localizedDescription)")
            // Fallback to AssetReader decoder (for non-SSL failures)
            plog("↳ Trying AssetReader fallback...")
            await playWithFallbackDecoder(song: song, url: url, outputFormat: outputFormat, playID: id)
        }
    }

    /// Prefetch the next song in the queue to local cache for instant playback.
    private func prefetchNextSong() {
        prefetchTask?.cancel()
        let nextIdx = currentIndex + 1
        guard nextIdx < queue.count else { return }
        let nextSong = queue[nextIdx]

        // Already cached? Nothing to do.
        if sourceManager?.cachedURL(for: nextSong) != nil { return }

        prefetchTask = Task {
            plog("⏩ Prefetching next song: \(nextSong.title)")
            sourceManager?.cacheInBackground(song: nextSong)
        }
    }

    /// Fallback playback using AVAssetReader when native decoder fails.
    private func playWithFallbackDecoder(song: Song, url: URL, outputFormat: AVAudioFormat, playID id: UUID) async {
        guard assetReaderDecoder.canDecode(url: url) else {
            plog("⚠️ No decoder available for '\(song.title)'")
            showPlaybackError(String(localized: "playback_error_format"))
            isLoading = false
            if currentIndex < queue.count - 1 { await next() }
            return
        }

        plog("↳ AVAssetReader fallback for '\(song.title)' url=\(url.scheme ?? "")://... ext=\(url.pathExtension)")

        let fallbackStream = assetReaderDecoder.decode(from: url, outputFormat: outputFormat)
        let iteratorBox = BufferIteratorBox(fallbackStream.makeAsyncIterator())

        do {
            guard let firstBuffer = try await iteratorBox.next() else {
                isLoading = false
                if currentIndex < queue.count - 1 { await next() }
                return
            }
            guard playID == id else { return }

            plog("↳ AssetReader firstBuffer: frames=\(firstBuffer.frameLength) format=sr\(firstBuffer.format.sampleRate)/ch\(firstBuffer.format.channelCount)")
            activeDecoderKind = .assetReader
            // Check if buffer has actual audio data (not all zeros)
            if let channelData = firstBuffer.floatChannelData?[0] {
                let frameCount = Int(firstBuffer.frameLength)
                var maxSample: Float = 0
                for i in 0..<min(frameCount, 1000) {
                    maxSample = max(maxSample, abs(channelData[i]))
                }
                plog("↳ AssetReader firstBuffer maxSample=\(maxSample) (0 = silence/broken)")
            }
            audioEngine.scheduleBuffer(firstBuffer)
            audioEngine.play()

            // Fetch duration asynchronously
            if duration <= 0 {
                Task {
                    if let info = await self.assetReaderDecoder.fileInfo(for: url) {
                        guard self.playID == id else { return }
                        self.duration = info.duration.sanitizedDuration
                        self.updateNowPlayingInfo()
                    }
                }
            }

            // Transition state after audio starts
            isPlaying = true
            isLoading = false
            clearPendingPlaybackRecovery()
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
                        plog("⚠️ AssetReader fallback decode error: \(error.localizedDescription)")
                    }
                }

                if let finalBuffer = lastBuffer {
                    guard !Task.isCancelled, self.playID == id else { return }
                    self.scheduleLastBuffer(finalBuffer, playID: id)
                }
            }
        } catch {
            plog("⚠️ AssetReader fallback also failed: \(error.localizedDescription)")
            isLoading = false
            if currentIndex < queue.count - 1 { await next() }
        }
    }

    /// Schedule the final buffer of a track with the appropriate completion callback
    /// for track-end detection, respecting gapless and crossfade settings.
    private func scheduleLastBuffer(_ buffer: AVAudioPCMBuffer, playID id: UUID) {
        let settings = playbackSettings.snapshot()

        // Standard and crossfade modes both use completion callback for track-end detection
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

    func pause() {
        shouldResumeAfterInterruption = false
        syncPlaybackProgressFromEngine()
        audioEngine.pause()
        isPlaying = false
        stopTimeUpdater()
        updateNowPlayingInfo()
        updatePlaybackState()
    }

    func resume() {
        guard !isLoading, currentSong != nil else { return }
        if needsPlaybackRecovery {
            seek(to: pendingRecoveryTime, startPlaying: true, isRecovery: true)
            return
        }
        _ = AudioSessionManager.shared.activatePlaybackSession()
        audioEngine.resume()
        syncPlaybackProgressFromEngine()
        isPlaying = true
        shouldResumeAfterInterruption = false
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
        currentSong = nil
        currentTime = 0
        duration = 0
        clearPendingPlaybackRecovery()
        stopTimeUpdater()
        // Clear NowPlaying info so Dynamic Island / Lock Screen also clears
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        updatePlaybackState()
    }

    func next() async {
        guard !queue.isEmpty else { return }
        advanceToNextIndex()
        await play(song: queue[currentIndex])
    }

    func previous() async {
        guard !queue.isEmpty else { return }
        if currentTime > 3 {
            seek(to: 0)
            return
        }
        if shuffleEnabled {
            shufflePosition = max(0, shufflePosition - 1)
            currentIndex = shuffledIndices.isEmpty ? 0 : shuffledIndices[shufflePosition]
        } else {
            currentIndex = currentIndex > 0 ? currentIndex - 1 : queue.count - 1
        }
        await play(song: queue[currentIndex])
    }

    private var seekTimeOffset: TimeInterval = 0

    func seek(to time: TimeInterval, startPlaying: Bool? = nil, isRecovery: Bool = false) {
        let requestedTime = TimeInterval.sanitized(time)
        let safeDuration = duration.sanitizedDuration
        let targetTime = safeDuration > 0 ? min(requestedTime, safeDuration) : requestedTime
        currentTime = targetTime
        isLoading = true
        updateNowPlayingInfo()

        guard let song = currentSong else { isLoading = false; return }
        let savedDuration = duration
        let shouldStartPlaying = startPlaying ?? isPlaying

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
        currentTime = targetTime
        duration = savedDuration

        Task {
            do {
                let url = try await resolvedURL(for: song)
                guard playID == id else { return }
                _ = AudioSessionManager.shared.activatePlaybackSession()
                try audioEngine.setUp()
                guard let outputFormat = audioEngine.outputFormat else { return }
                try audioEngine.start()

                let settings = playbackSettings.snapshot()
                if settings.replayGainEnabled {
                    await applyReplayGain(for: url, mode: settings.replayGainMode)
                }

                // Use the same decoder that was used for initial playback.
                // For streaming, require the cached local file — can't seek in remote streams.
                let seekURL: URL
                if activeDecoderKind == .streaming {
                    guard let cached = sourceManager?.cachedURL(for: song) else {
                        plog("⚠️ Seek: streaming song not cached yet, seek not available")
                        isLoading = false
                        if isRecovery {
                            clearPendingPlaybackRecovery()
                            await play(song: song)
                        }
                        return
                    }
                    seekURL = cached
                } else {
                    seekURL = url
                }
                let stream: AsyncThrowingStream<AVAudioPCMBuffer, Error>
                switch activeDecoderKind {
                case .native, .streaming:
                    stream = nativeDecoder.decode(from: seekURL, outputFormat: outputFormat)
                case .assetReader:
                    stream = assetReaderDecoder.decode(from: seekURL, outputFormat: outputFormat)
                }
                let seekSamplePosition = targetTime * outputFormat.sampleRate
                guard seekSamplePosition.isFinite else {
                    self.isLoading = false
                    self.updateNowPlayingInfo()
                    self.updatePlaybackState()
                    return
                }
                let seekSamples = Int64(seekSamplePosition.rounded(.down))
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

                guard let firstBuffer = firstPlayableBuffer else {
                    isLoading = false
                    return
                }
                guard playID == id else { return }

                audioEngine.scheduleBuffer(firstBuffer)
                if shouldStartPlaying { audioEngine.play() }

                isLoading = false
                if shouldStartPlaying {
                    isPlaying = true
                    startTimeUpdater()
                } else {
                    isPlaying = false
                }
                if isRecovery { clearPendingPlaybackRecovery() }
                updateNowPlayingInfo()
                updatePlaybackState()

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
                        if !Task.isCancelled { plog("Seek decode error: \(error)") }
                    }

                    if let finalBuffer = lastBuffer {
                        guard !Task.isCancelled, self.playID == id else { return }
                        self.scheduleLastBuffer(finalBuffer, playID: id)
                    }
                }
            } catch {
                plog("Seek error: \(error)")
                isLoading = false
                updateNowPlayingInfo()
                updatePlaybackState()
            }
        }
    }

    func handleAppWillResignActive() {
        syncPlaybackProgressFromEngine()
        updateNowPlayingInfo()
        updatePlaybackState()
    }

    func handleAppDidBecomeActive() {
        if shouldResumeAfterInterruption, !isPlaying, currentSong != nil {
            resume()
            return
        }

        if needsPlaybackRecovery {
            currentTime = max(0, pendingRecoveryTime)
            updateNowPlayingInfo()
            updatePlaybackState()
            return
        }

        syncPlaybackProgressFromEngine()
        updateNowPlayingInfo()
        updatePlaybackState()
    }

    func setQueue(_ songs: [Song], startAt index: Int = 0) {
        queue = songs
        currentIndex = min(index, songs.count - 1)
        if shuffleEnabled { rebuildShuffleOrder() }
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
            plog("🔄 gaplessPreload: ABORTED (playID mismatch)")
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
            plog("🔄 gaplessPreload: currentSong → \(nextSong.title)")
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
                            self.duration = info.duration.sanitizedDuration
                        }
                    }
                    updateNowPlayingInfo()
                    updateNowPlayingArtworkIfNeeded()
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
            plog("Gapless preload error: \(error)")
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
        guard let nextSong = nextSongInQueue() else {
            crossfadeTriggered = false
            return
        }

        do {
            let nextURL = try await resolvedURL(for: nextSong)
            guard nativeDecoder.canDecode(url: nextURL),
                  let outputFormat = audioEngine.outputFormat else {
                crossfadeTriggered = false
                return
            }

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
                    if !Task.isCancelled { plog("Crossfade decode error: \(error)") }
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
            plog("Crossfade start error: \(error)")
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
                    // Equal-power crossfade curve: maintains perceived loudness
                    // through the transition (no "dip" in the middle like linear)
                    let angle = Double(progress) * .pi / 2
                    self.audioEngine.setCrossfadeVolumes(
                        primary: Float(cos(angle)),
                        crossfade: Float(sin(angle))
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
        plog("🔄 completeCrossfade: currentSong → \(nextSong.title)")
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
        updateNowPlayingArtworkIfNeeded()
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
                    self.currentTime = time.sanitizedDuration

                    // Safety net: if currentTime exceeds duration, the completion callback
                    // may have failed to fire — force track advancement.
                    if self.duration > 0, self.currentTime >= self.duration + 1.0, !self.isLoading {
                        plog("⚠️ Safety net: currentTime (\(self.currentTime)) exceeded duration (\(self.duration)), forcing track end")
                        self.stopTimeUpdater()
                        await self.handleTrackEnd()
                        return
                    }
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
        plog("⏭️ handleTrackEnd() currentSong=\(currentSong?.title ?? "nil") playID=\(playID?.uuidString.prefix(8) ?? "nil")")
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
            let nextPos = shufflePosition + 1
            if nextPos < shuffledIndices.count {
                nextIndex = shuffledIndices[nextPos]
            } else if repeatMode == .all {
                return queue.first // will reshuffle on advanceToNextIndex
            } else {
                return nil
            }
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
            shufflePosition += 1
            if shufflePosition >= shuffledIndices.count {
                rebuildShuffleOrder()
                shufflePosition = 0
            }
            currentIndex = shuffledIndices.isEmpty ? 0 : shuffledIndices[shufflePosition]
        } else {
            currentIndex = (currentIndex + 1) % queue.count
        }
    }

    private func rebuildShuffleOrder() {
        guard !queue.isEmpty else { shuffledIndices = []; return }
        shuffledIndices = Array(0..<queue.count).shuffled()
        shufflePosition = 0
        // Place current index at position 0 so current song stays first
        if let pos = shuffledIndices.firstIndex(of: currentIndex) {
            shuffledIndices.swapAt(0, pos)
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
                let url = try await sourceManager.resolveURL(for: song)
                plog("🔗 resolvedURL for '\(song.title)': \(url.isFileURL ? "LOCAL" : url.scheme?.uppercased() ?? "?") → \(url.absoluteString.prefix(120))")
                return url
            } catch {
                plog("🔗 resolveURL failed for '\(song.title)': \(error), filePath=\(song.filePath.prefix(80))")
                if song.filePath.hasPrefix("/") {
                    return URL(fileURLWithPath: song.filePath)
                }
                throw error
            }
        }
        if let remoteURL = URL(string: song.filePath), remoteURL.scheme != nil {
            plog("🔗 resolvedURL for '\(song.title)': direct remote → \(remoteURL.absoluteString.prefix(80))")
            return remoteURL
        }
        plog("🔗 resolvedURL for '\(song.title)': file path → \(song.filePath.prefix(80))")
        return URL(fileURLWithPath: song.filePath)
    }

    // MARK: - Now Playing Info

    /// Tracks which cover we last loaded to avoid redundant disk reads
    private var lastArtworkFileName: String?

    private func updateNowPlayingInfo() {
        guard currentSong != nil else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }

        let elapsedTime = max(0, min(currentTime, duration > 0 ? duration : currentTime))

        // Create fresh info but preserve existing artwork
        var info = [String: Any]()
        info[MPMediaItemPropertyTitle] = currentSong?.title ?? ""
        info[MPMediaItemPropertyArtist] = currentSong?.artistName ?? ""
        info[MPMediaItemPropertyAlbumTitle] = currentSong?.albumTitle ?? ""
        info[MPMediaItemPropertyPlaybackDuration] = duration
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsedTime
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0

        // Carry over existing artwork (set separately by updateNowPlayingArtworkIfNeeded)
        if let existingArtwork = MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork] {
            info[MPMediaItemPropertyArtwork] = existingArtwork
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// Call ONLY when song changes — loads cover art and sets MPMediaItemPropertyArtwork
    private func updateNowPlayingArtworkIfNeeded() {
        let songID = currentSong?.id
        guard songID != lastArtworkFileName else { return }
        lastArtworkFileName = songID

        // Immediately clear stale artwork from previous song so Dynamic Island
        // doesn't keep showing the old cover while loading the new one.
        var nowInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        nowInfo[MPMediaItemPropertyArtwork] = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowInfo

        guard let songID else { return }
        let coverRef = currentSong?.coverArtFileName
        let capturedSourceID = currentSong?.sourceID
        let capturedFilePath = currentSong?.filePath
        let capturedSourceManager = sourceManager

        Task.detached(priority: .userInitiated) { [weak self] in
            guard self != nil else { return }
            let store = MetadataAssetStore.shared
            let artworkDir = store.artworkDirectoryURL

            // Tier 1: songID-based cache
            var loadedImage: UIImage?
            let hashedName = store.expectedCoverFileName(for: songID)
            if let data = try? Data(contentsOf: artworkDir.appendingPathComponent(hashedName)) {
                loadedImage = UIImage(data: data)
            }

            // Tier 2: legacy filename (local hashed filename, no "/" or "://")
            if loadedImage == nil, let coverRef, !coverRef.isEmpty,
               !coverRef.contains("/"), !coverRef.contains("://") {
                if let data = try? Data(contentsOf: artworkDir.appendingPathComponent(coverRef)) {
                    loadedImage = UIImage(data: data)
                }
            }

            // Tier 3: source fetch — URL reference or sidecar path
            if loadedImage == nil, let coverRef, !coverRef.isEmpty {
                var fetchedData: Data?
                // Full URL (media server API)
                if coverRef.contains("://"), let url = URL(string: coverRef) {
                    let config = URLSessionConfiguration.default
                    config.timeoutIntervalForRequest = 10
                    let session = URLSession(configuration: config, delegate: SmartSSLDelegate(), delegateQueue: nil)
                    fetchedData = try? await session.data(from: url).0
                }
                // Sidecar path on source (contains "/" but no "://")
                else if coverRef.contains("/"), let sourceID = capturedSourceID,
                        let sourceManager = capturedSourceManager {
                    if let imageURL = await sourceManager.imageURL(for: coverRef, sourceID: sourceID) {
                        let config = URLSessionConfiguration.default
                        config.timeoutIntervalForRequest = 10
                        let session = URLSession(configuration: config, delegate: SmartSSLDelegate(), delegateQueue: nil)
                        fetchedData = try? await session.data(from: imageURL).0
                    }
                }
                if let data = fetchedData {
                    // Cache for next time
                    await store.cacheCover(data, forSongID: songID)
                    loadedImage = UIImage(data: data)
                }
            }

            // Tier 4: embedded cover extraction from locally cached audio file
            if loadedImage == nil, let sourceID = capturedSourceID, let filePath = capturedFilePath,
               let sourceManager = capturedSourceManager {
                let dummySong = Song(id: "", title: "", fileFormat: .mp3, filePath: filePath,
                                     sourceID: sourceID, fileSize: 0, dateAdded: Date())
                if let cachedURL = await sourceManager.cachedURL(for: dummySong) {
                    let metadata = await FileMetadataReader.read(from: cachedURL)
                    if let coverData = metadata.coverArtData {
                        await store.cacheCover(coverData, forSongID: songID)
                        loadedImage = UIImage(data: coverData)
                    }
                }
            }

            // Guard: make sure we're still on the same song before updating NowPlaying
            await MainActor.run { [weak self] in
                guard let self, self.currentSong?.id == songID else { return }
                var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
                if let image = loadedImage {
                    info[MPMediaItemPropertyArtwork] = Self.makeArtwork(from: image)
                } else {
                    info[MPMediaItemPropertyArtwork] = nil
                }
                MPNowPlayingInfoCenter.default().nowPlayingInfo = info
            }
        }
    }

    /// Force refresh NowPlaying artwork (e.g. after scraping updated the cover file).
    /// Resets lastArtworkFileName so the guard check passes.
    func forceRefreshNowPlayingArtwork() {
        lastArtworkFileName = nil
        updateNowPlayingArtworkIfNeeded()
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
        let safeImage = image
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

    // MARK: - Sleep Timer

    func scheduleSleep(minutes: Int) {
        cancelSleep()
        let endDate = Date().addingTimeInterval(TimeInterval(minutes * 60))
        sleepTimerEndDate = endDate
        sleepTimerTask = Task {
            try? await Task.sleep(for: .seconds(minutes * 60))
            guard !Task.isCancelled else { return }
            self.pause()
            self.sleepTimerEndDate = nil
        }
    }

    func cancelSleep() {
        sleepTimerTask?.cancel()
        sleepTimerTask = nil
        sleepTimerEndDate = nil
    }

    // MARK: - Shared Playback State

    /// Tracks the last songID for which we wrote a widget cover, to avoid redundant writes.
    private var lastWidgetCoverSongID: String?
    /// Coalesces repeated WidgetKit reload requests with identical content.
    private var lastWidgetTimelineSignature: String?

    private func updatePlaybackState() {
        var coverName: String?
        var recentAlbumsChanged = false

        if let song = currentSong {
            let sharedCoverName = "widget_cover.png"
            let needsSharedCoverRefresh = song.id != lastWidgetCoverSongID || !sharedWidgetCoverExists(named: sharedCoverName)

            if needsSharedCoverRefresh {
                if let writtenCoverName = writeWidgetCover(song: song, fileName: sharedCoverName) {
                    coverName = writtenCoverName
                    lastWidgetCoverSongID = song.id
                } else if sharedWidgetCoverExists(named: sharedCoverName) {
                    coverName = sharedCoverName
                    lastWidgetCoverSongID = song.id
                } else {
                    lastWidgetCoverSongID = nil
                }

                if let albumEntry = makeRecentAlbumEntry(for: song) {
                    if let albumCoverName = albumEntry.coverImageName,
                       !sharedWidgetCoverExists(named: albumCoverName) {
                        _ = writeWidgetCover(song: song, fileName: albumCoverName, size: 200)
                    }
                    RecentAlbumsStore.record(albumEntry)
                    recentAlbumsChanged = true
                }
            } else {
                coverName = sharedCoverName
            }
        } else {
            lastWidgetCoverSongID = nil
        }

        let state = PlaybackState(
            currentSongID: currentSong?.id,
            songTitle: currentSong?.title,
            artistName: currentSong?.artistName,
            albumTitle: currentSong?.albumTitle,
            coverImageName: coverName,
            isPlaying: isPlaying,
            currentTime: currentTime,
            duration: duration,
            queueSongIDs: queue.map(\.id)
        )
        state.save()

        let timelineSignature = widgetTimelineSignature(for: state)
        if recentAlbumsChanged || timelineSignature != lastWidgetTimelineSignature {
            lastWidgetTimelineSignature = timelineSignature
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    /// Writes a cover image to the App Group shared container for Widget rendering.
    /// Returns the filename if successful.
    @discardableResult
    private func writeWidgetCover(song: Song, fileName: String, size: CGFloat = 300) -> String? {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: PrimuseConstants.appGroupIdentifier
        ) else { return nil }

        let store = MetadataAssetStore.shared
        let artworkDir = store.artworkDirectoryURL

        // Try songID-based cache first
        var coverData: Data?
        let hashedName = store.expectedCoverFileName(for: song.id)
        let hashedURL = artworkDir.appendingPathComponent(hashedName)
        if FileManager.default.fileExists(atPath: hashedURL.path) {
            coverData = try? Data(contentsOf: hashedURL)
        }

        // Fallback: legacy local filename
        if coverData == nil, let ref = song.coverArtFileName, !ref.isEmpty,
           !ref.contains("/"), !ref.contains("://") {
            let legacyURL = artworkDir.appendingPathComponent(ref)
            if FileManager.default.fileExists(atPath: legacyURL.path) {
                coverData = try? Data(contentsOf: legacyURL)
            }
        }

        guard let data = coverData, let originalImage = UIImage(data: data) else {
            return nil
        }

        let targetSize = CGSize(width: size, height: size)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = true

        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        let resizedImage = renderer.image { context in
            UIColor.black.setFill()
            context.fill(CGRect(origin: .zero, size: targetSize))
            let sourceAspect = originalImage.size.width / originalImage.size.height
            let drawRect: CGRect
            if sourceAspect > 1 {
                let scaledWidth = targetSize.height * sourceAspect
                let xOffset = (targetSize.width - scaledWidth) / 2
                drawRect = CGRect(x: xOffset, y: 0, width: scaledWidth, height: targetSize.height)
            } else {
                let scaledHeight = targetSize.width / sourceAspect
                let yOffset = (targetSize.height - scaledHeight) / 2
                drawRect = CGRect(x: 0, y: yOffset, width: targetSize.width, height: scaledHeight)
            }
            originalImage.draw(in: drawRect)
        }

        guard let jpegData = resizedImage.jpegData(compressionQuality: 0.8) else { return nil }

        let destinationURL = containerURL.appendingPathComponent(fileName)

        do {
            try jpegData.write(to: destinationURL, options: .atomic)
            return fileName
        } catch {
            return nil
        }
    }

    private func sharedWidgetCoverExists(named fileName: String) -> Bool {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: PrimuseConstants.appGroupIdentifier
        ) else {
            return false
        }
        return FileManager.default.fileExists(atPath: containerURL.appendingPathComponent(fileName).path)
    }

    private func makeRecentAlbumEntry(for song: Song) -> RecentAlbumEntry? {
        guard let rawAlbumTitle = song.albumTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawAlbumTitle.isEmpty else {
            return nil
        }

        let artistName = song.artistName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let albumKey = stableWidgetAlbumKey(for: song, albumTitle: rawAlbumTitle, artistName: artistName)
        let coverImageName = "widget_album_\(albumKey).jpg"

        return RecentAlbumEntry(
            id: albumKey,
            title: rawAlbumTitle,
            artistName: artistName,
            coverImageName: coverImageName
        )
    }

    private func stableWidgetAlbumKey(for song: Song, albumTitle: String, artistName: String) -> String {
        let baseKey = song.albumID ?? "\(song.sourceID)|\(albumTitle.lowercased())|\(artistName.lowercased())"
        let digest = SHA256.hash(data: Data(baseKey.utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    private func widgetTimelineSignature(for state: PlaybackState) -> String {
        [
            state.currentSongID ?? "",
            state.songTitle ?? "",
            state.artistName ?? "",
            state.albumTitle ?? "",
            state.coverImageName ?? "",
            state.isPlaying ? "1" : "0",
            String(Int(state.currentTime.rounded())),
            String(Int(state.duration.rounded()))
        ].joined(separator: "|")
    }
}
