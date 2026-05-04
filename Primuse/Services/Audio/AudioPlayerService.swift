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

/// Sendable carrier for AVAudioPCMBuffer across task boundaries.
/// AVAudioPCMBuffer is a reference type marked non-Sendable by AVFoundation,
/// but we only ever read it after the producing task completes, so the box is
/// safe in practice.
private struct PCMBufferBox: @unchecked Sendable {
    let value: AVAudioPCMBuffer?
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
    /// 「歌播完了但 queue 没下一首」的状态 —— Apple Music / Spotify 风格的
    /// "已播完待重播"。currentSong / queue / currentIndex 全保留, 只是
    /// 引擎停了 + currentTime = 0 + isPlaying = false。用户点 play 会从头
    /// 重放当前曲。这个状态存在的意义: 别让 currentSong 变 nil ——
    /// 否则 NowPlayingView / 刮削 sheet / mini player 全是空白屏 (因为
    /// 它们都靠 currentSong 渲染)。
    ///
    /// 触发: handleTrackEnd .off + nextSongInQueue() == nil
    /// 退出: play(song:) / stop() / resume() (resume 会把当前歌重新 play)
    private(set) var isAtTrackEnd = false
    /// `currentTimeAnchor` 在 didSet 里自动同步 wall-clock，配合 `interpolatedTime(at:)`
    /// 在 0.5s 引擎采样间隙内做线性外推，让 60Hz 字级歌词动画无抖。
    private(set) var currentTime: TimeInterval = 0 {
        didSet { currentTimeAnchor = Date() }
    }
    private(set) var duration: TimeInterval = 0
    private(set) var isLoading = false
    private(set) var lastPlaybackError: String?

    private(set) var currentTimeAnchor: Date = Date()

    /// 在 `currentTime` 与下一次 0.5s 采样之间做线性外推，每次 currentTime
    /// 真实更新（didSet 重置 anchor）就跟引擎报告时间校准一次,不会累积漂移。
    func interpolatedTime(at date: Date = Date()) -> TimeInterval {
        guard isPlaying, !isLoading else { return currentTime }
        let elapsed = max(0, date.timeIntervalSince(currentTimeAnchor))
        // 单次外推不超过 1s——异常情况（后台/中断）出现大间隙时不要漂太远
        let safeElapsed = min(elapsed, 1.0)
        let extrapolated = currentTime + safeElapsed
        if duration > 0 { return min(extrapolated, duration) }
        return extrapolated
    }

    var queue: [Song] = []
    var currentIndex: Int = 0
    var shuffleEnabled = false {
        didSet { rebuildShuffleOrder() }
    }
    var repeatMode: RepeatMode = .off

    // MARK: - Shuffle Order
    private var shuffledIndices: [Int] = []
    private var shufflePosition: Int = 0
    /// Pre-computed next round used by repeat-all wrap-around. Generated
    /// when the current round nears its end so `nextSongInQueue` (used
    /// by prefetch) and `advanceToNextIndex` (the actual advance) agree
    /// on what plays next at the boundary. Cleared on any structural
    /// change to `queue` / shuffle state.
    private var pendingNextShuffleIndices: [Int]?

    // MARK: - Decoder Tracking (for seek)
    /// Tracks which decoder pipeline produced the currently-playing audio
    /// stream so seek/crossfade/recovery can reproduce the exact same path.
    /// `cloudStream` means SFBAudio decoding from a `CloudPlaybackSource`
    /// `InputSource` (Range-fetch + sparse cache). Seeking that path
    /// requires building a NEW `InputSource` — feeding the
    /// `primuse-stream://` URL to SFB's URL-based opener fails because
    /// the scheme isn't registered with the file system.
    private enum DecoderKind { case native, streaming, cloudStream, assetReader }
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
    /// crossfade 进行中 —— 用来让 startTimeUpdater 跳过 currentTime 更新。
    /// crossfade 期间 audioEngine.currentTime 还是旧曲的 primary node 时间,
    /// 但 UI 已经切到新曲, 这两值对不上, 直接刷会让进度条乱跳。crossfade
    /// 完成 swap 后 isCrossfading 清零, currentTime 跟随新 primary node。
    private var isCrossfading = false
    private var playID: UUID?

    private var errorDismissTask: Task<Void, Never>?
    private var shouldResumeAfterInterruption = false
    private var needsPlaybackRecovery = false
    private var pendingRecoveryTime: TimeInterval = 0

    /// Seconds of buffered audio we let drain before forcibly advancing
    /// after a mid-stream decode error. Without this cap, the ~100 buffers
    /// already scheduled to the playerNode play out for ~20s before
    /// `autoAdvanceAfterFailure` fires — looks like the player is frozen
    /// (most painfully on CarPlay where the user has no other UI to fall
    /// back to). 3s is enough that the user hears "this song stuttered"
    /// rather than a sudden cut, but short enough to feel responsive.
    private static let midStreamErrorGrace: TimeInterval = 3

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

        // 切到新歌前主动触发上一首的 streaming session finalize, 让它有机会
        // 把 .partial 转成 final (如果缺口在 50MB 自动补齐阈值内)。
        if let prev = currentSong, prev.id != song.id {
            sourceManager?.finalizeStreamingSession(for: prev)
        }

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
        isAtTrackEnd = false
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
            await autoAdvanceAfterFailure()
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
        crossfadeTriggered = false; isCrossfading = false
        activeDecoderKind = .native

        let isRemoteURL = url.scheme == "http" || url.scheme == "https"
        let isCloudStream = url.scheme == SourceManager.cloudStreamingScheme

        guard isRemoteURL || isCloudStream || nativeDecoder.canDecode(url: url) else {
            plog("Unsupported format: \(url.pathExtension)")
            isLoading = false
            await autoAdvanceAfterFailure()
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

            // Cloud streaming: instead of downloading the whole file, build
            // an SFBInputSource whose reads go through HTTP Range +
            // sparse-on-disk cache. SFBAudioEngine reads from it like any
            // file and we get instant playback.
            let stream: AsyncThrowingStream<AVAudioPCMBuffer, Error>
            if isCloudStream, let manager = sourceManager,
               let inputSource = try? await manager.makeStreamingInputSource(
                   for: song,
                   cacheEnabled: playbackSettings.audioCacheEnabled
               ) {
                plog("▶️ Using CloudPlaybackSource (streaming SFBInputSource, cache=\(playbackSettings.audioCacheEnabled))")
                activeDecoderKind = .cloudStream
                stream = nativeDecoder.decode(from: inputSource, outputFormat: outputFormat, onResolveSourceLength: makeResolveLengthCallback(for: song))
            } else {
                // Local file path (or fallback when streaming setup failed)
                stream = nativeDecoder.decode(from: url, outputFormat: outputFormat, onResolveSourceLength: makeResolveLengthCallback(for: song))
            }
            let iteratorBox = BufferIteratorBox(stream.makeAsyncIterator())

            // Await first buffer — ensures we have audio data before calling play()
            // Wrapped in a 35s timeout race so a hung cloud fetch (revoked
            // dlink that never errors out, account-banned network stall)
            // doesn't leave the play button spinning forever. The
            // CloudPlaybackSource serve has its own 30s per-chunk timeout
            // — this one is the outer safety net.
            let firstBuffer: AVAudioPCMBuffer
            do {
                let box: PCMBufferBox = try await withThrowingTaskGroup(of: PCMBufferBox.self) { group in
                    group.addTask {
                        let b = try await iteratorBox.next()
                        return PCMBufferBox(value: b)
                    }
                    group.addTask {
                        try? await Task.sleep(for: .seconds(35))
                        throw CancellationError()
                    }
                    let first = try await group.next() ?? PCMBufferBox(value: nil)
                    group.cancelAll()
                    return first
                }
                guard let buffer = box.value else {
                    // Empty stream — skip to next
                    isLoading = false
                    await autoAdvanceAfterFailure()
                    return
                }
                guard playID == id else { return }
                firstBuffer = buffer
            } catch is CancellationError {
                guard !Task.isCancelled, playID == id else { return }
                plog("⚠️ '\(song.title)' first-buffer timeout (35s) — likely cloud fetch stalled")
                showPlaybackError(String(localized: "playback_error_connection"))
                isLoading = false
                await autoAdvanceAfterFailure()
                return
            } catch {
                // Native decode failed on first buffer — try fallback decoder.
                // Cloud-stream URLs can't be opened by the FFmpeg fallback,
                // so let the caller surface the error instead.
                guard !Task.isCancelled, playID == id else { return }
                plog("⚠️ Native decode failed for '\(song.title)': \(error.localizedDescription)")
                if !isCloudStream {
                    await playWithFallbackDecoder(song: song, url: url, outputFormat: outputFormat, playID: id)
                } else {
                    isLoading = false
                }
                return
            }

            // Schedule first buffer BEFORE play — playerNode has data ready
            plog("▶️ NativeDecoder firstBuffer: frames=\(firstBuffer.frameLength) format=sr\(firstBuffer.format.sampleRate)/ch\(firstBuffer.format.channelCount)")
            plog("▶️ Engine state: outputFormat=sr\(outputFormat.sampleRate)/ch\(outputFormat.channelCount) mainVol=\(audioEngine.volume)")
            plog("▶️ Engine diagnostics: \(audioEngine.diagnosticInfo())")
            audioEngine.scheduleBuffer(firstBuffer)
            audioEngine.play()
            plog("▶️ After play(): \(audioEngine.diagnosticInfo())")

            // Fetch duration asynchronously if not already known.
            // Skip for cloud-stream URLs — fileInfo opens via SFBAudioEngine
            // by URL, which doesn't understand the custom scheme. Duration
            // for cloud songs is filled in by MetadataBackfillService.
            if duration <= 0, !isCloudStream {
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
            ScrobbleService.shared.handlePlaybackStarted(song: song); PlayHistoryStore.shared.beginSession(song: song)
            startTimeUpdater()
            updateNowPlayingInfo()
            updateNowPlayingArtworkIfNeeded()
            updatePlaybackState()

            // Apply ReplayGain in background (don't block playback start).
            // Skip for cloud-stream URLs — readers open by URL and can't
            // decode the custom scheme. Once playback finishes the cache
            // file is fully populated and a future play picks up RG.
            let settings = playbackSettings.snapshot()
            if settings.replayGainEnabled, !isCloudStream {
                Task { [id] in
                    await self.applyReplayGain(for: url, mode: settings.replayGainMode)
                    guard self.playID == id else { return }
                }
            }

            // Background-cache file for offline playback (if enabled).
            // Cloud streaming already writes to the same cache file as
            // it goes — duplicating via cacheInBackground would just
            // race two writers on the same path.
            if playbackSettings.audioCacheEnabled, !isCloudStream {
                sourceManager?.cacheInBackground(song: song, cacheEnabled: playbackSettings.audioCacheEnabled)
            }

            // Prefetch next song
            prefetchNextSong()

            // Decode remaining buffers in background task (hold-last for completion callback)
            decodingTask = Task { [id, iteratorBox] in
                var lastBuffer: AVAudioPCMBuffer?
                var scheduledCount = 0
                var midStreamError = false

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
                    guard !Task.isCancelled, self.playID == id else { return }
                    midStreamError = true
                    plog("⚠️ Decode error mid-stream for '\(song.title)' (scheduled \(scheduledCount) buffers): \(error.localizedDescription)")
                    self.showPlaybackError(String(localized: "playback_error_decode"))
                    if scheduledCount < 3 {
                        // Too little decoded to be worth playing — bail now.
                        // Helper handles repeat-one (stop, don't loop broken
                        // file), shuffle correctness, and stop-when-no-next.
                        await self.autoAdvanceAfterFailure()
                        return
                    }
                }

                guard !Task.isCancelled, self.playID == id else { return }
                if midStreamError {
                    // Cap the post-error grace period at `midStreamErrorGrace`.
                    // Without the cap, ~100 already-scheduled buffers would
                    // play out for ~20s before `autoAdvanceAfterFailure`
                    // fires (via the lastBuffer's `dataPlayedBack`
                    // completion). On CarPlay that looked like the player
                    // was frozen — no progress, no skip, until the buffer
                    // queue finally drained. Spawn a short timer Task that
                    // hard-cuts the audio engine and advances; whichever
                    // event happens first wins.
                    Task { @MainActor [id] in
                        try? await Task.sleep(for: .seconds(Self.midStreamErrorGrace))
                        guard self.playID == id else { return }
                        plog("🛑 mid-stream grace elapsed; stopping engine and advancing")
                        self.audioEngine.stopPlayback()
                        await self.autoAdvanceAfterFailure()
                    }
                } else if let finalBuffer = lastBuffer {
                    // Natural EOF — schedule with track-end completion.
                    self.scheduleLastBuffer(finalBuffer, playID: id)
                }
            }
        } catch {
            plog("⚠️ Playback error for '\(song.title)': \(error.localizedDescription)")
            showPlaybackError(String(localized: "playback_error_decode"))
            isLoading = false
            // Auto-skip on decode failure (or stop under repeat-one
            // instead of looping a broken file).
            await autoAdvanceAfterFailure()
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
                await autoAdvanceAfterFailure()
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
            ScrobbleService.shared.handlePlaybackStarted(song: song); PlayHistoryStore.shared.beginSession(song: song)
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
                            // Helper handles stop()/next()/repeat-one
                            // semantics — don't pre-stop here, otherwise
                            // we'd race the next()-→play() restart.
                            await self.autoAdvanceAfterFailure()
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
    /// Decode any URL produced by `resolvedURL`, transparently handling
    /// the `primuse-stream://` custom scheme by building a fresh
    /// `CloudPlaybackSource` InputSource. Crossfade/gapless/seek paths all
    /// go through here so they stay correct when the source is a cloud
    /// streaming song.
    /// Build the duration-rewrite callback for a song. Every decode
    /// path (fresh play, crossfade prefetch, seek) routes through this
    /// so the first time SFB sees the full stream we capture the real
    /// PCM frame count and rewrite the library — backfill's
    /// 256KB-head estimate (especially for raw MP3) is replaced by
    /// the authoritative value, and the row's displayed time is
    /// correct from then on.
    private func makeResolveLengthCallback(for song: Song) -> @Sendable (TimeInterval) -> Void {
        let songID = song.id
        let songTitle = song.title
        let storedDuration = song.duration
        let fileSize = song.fileSize
        let bitRate = song.bitRate
        let fileFormat = song.fileFormat
        return { [weak self] resolved in
            guard resolved > 0 else { return }
            if Self.isLikelyTruncatedCloudDuration(
                resolved: resolved,
                stored: storedDuration,
                fileSize: fileSize,
                bitRateKbps: bitRate,
                format: fileFormat
            ) {
                plog(String(format: "⚠️ Ignoring implausible SFB duration for '%@': %.1fs (stored %.1fs, size=%lldKB) — likely partial cloud read",
                            songTitle, resolved, storedDuration, fileSize / 1024))
                return
            }
            // Skip rewrite when the parser/backfill already had it
            // right (within 5%) — avoids library churn + UI thrash
            // for songs with a clean LAME header or m4a `mvhd`.
            let needsRewrite = storedDuration <= 0
                || abs(storedDuration - resolved) / max(resolved, 1) > 0.05
            guard needsRewrite else { return }
            Task { @MainActor [weak self] in
                guard let self, let library = self.library else { return }
                guard var existing = library.songs.first(where: { $0.id == songID }) else { return }
                existing.duration = resolved
                library.replaceSong(existing)
                plog(String(format: "🎵 SFB resolved real duration for '%@': %.1fs (was %.1fs) — rewrote library", songTitle, resolved, storedDuration))
            }
        }
    }

    nonisolated private static func isLikelyTruncatedCloudDuration(
        resolved: TimeInterval,
        stored: TimeInterval,
        fileSize: Int64,
        bitRateKbps: Int?,
        format: AudioFormat
    ) -> Bool {
        if stored > 30, resolved < stored * 0.5 {
            return true
        }

        guard format == .mp3, fileSize > 512 * 1024 else {
            return false
        }
        let effectiveBitRate = max(bitRateKbps ?? 0, 192)
        let estimatedFromFileSize = Double(fileSize) / (Double(effectiveBitRate) * 125.0)
        return estimatedFromFileSize > 30 && resolved < estimatedFromFileSize * 0.5
    }

    private func decodeStream(
        for song: Song,
        url: URL,
        outputFormat: AVAudioFormat
    ) async -> AsyncThrowingStream<AVAudioPCMBuffer, Error>? {
        let onResolveLength = makeResolveLengthCallback(for: song)

        if url.scheme == SourceManager.cloudStreamingScheme {
            // Prefer fully-cached file if available (skips streaming overhead).
            if let cached = sourceManager?.cachedURL(for: song) {
                return nativeDecoder.decode(from: cached, outputFormat: outputFormat, onResolveSourceLength: onResolveLength)
            }
            guard let manager = sourceManager,
                  let inputSource = try? await manager.makeStreamingInputSource(
                      for: song,
                      cacheEnabled: playbackSettings.audioCacheEnabled
                  ) else {
                return nil
            }
            return nativeDecoder.decode(from: inputSource, outputFormat: outputFormat, onResolveSourceLength: onResolveLength)
        }
        return nativeDecoder.decode(from: url, outputFormat: outputFormat, onResolveSourceLength: onResolveLength)
    }

    private func prefetchNextSong() {
        prefetchTask?.cancel()
        // Prefetch 接下来 3 首,而不是只 1 首 —— 用户连续 next 切歌时
        // (4-5s/次), 单首 prefetch chain 来不及, 第 2、3 首切到时 partial
        // 还是空, SFB 现拉 1MB chunk 卡 2-3s。3 首并发 prewarm 流量是
        // 3 * 1.25MB = 3.75MB, NAS 内网完全 cover 得了。
        let nextSongs = nextSongsInQueue(count: 3)
        guard !nextSongs.isEmpty else { return }

        prefetchTask = Task {
            for song in nextSongs {
                if Task.isCancelled { return }
                if song.id == currentSong?.id { continue }
                if sourceManager?.cachedURL(for: song) != nil { continue }
                plog("⏩ Prefetching next song: \(song.title)")
                sourceManager?.cacheInBackground(song: song, cacheEnabled: playbackSettings.audioCacheEnabled)
            }
        }
    }

    /// 返回 queue 接下来 N 首 (考虑 shuffle / repeat all)。N 首之间不重复。
    /// 用于 prefetch chain — 让用户连续 next 时也能命中 prewarm。
    private func nextSongsInQueue(count: Int) -> [Song] {
        guard !queue.isEmpty, count > 0 else { return [] }
        if repeatMode == .one { return [] }

        var result: [Song] = []
        var seenIDs = Set<String>()
        if let cur = currentSong { seenIDs.insert(cur.id) }

        if shuffleEnabled {
            var localPending: [Int]? = nil
            for offset in 1...count {
                let pos = shufflePosition + offset
                let song: Song?
                if pos < shuffledIndices.count {
                    song = queue[shuffledIndices[pos]]
                } else if repeatMode == .all {
                    let pending = localPending ?? pendingNextShuffleIndices ?? buildPendingNextRound()
                    if pendingNextShuffleIndices == nil { pendingNextShuffleIndices = pending }
                    localPending = pending
                    let pos2 = pos - shuffledIndices.count
                    song = pos2 < pending.count ? queue[pending[pos2]] : nil
                } else {
                    song = nil
                }
                if let s = song, !seenIDs.contains(s.id) {
                    result.append(s)
                    seenIDs.insert(s.id)
                }
            }
        } else {
            for offset in 1...count {
                let raw = currentIndex + offset
                let idx: Int?
                if raw < queue.count {
                    idx = raw
                } else if repeatMode == .all {
                    idx = raw % queue.count
                } else {
                    idx = nil
                }
                if let i = idx, !seenIDs.contains(queue[i].id) {
                    result.append(queue[i])
                    seenIDs.insert(queue[i].id)
                }
            }
        }
        return result
    }

    /// Fallback playback using AVAssetReader when native decoder fails.
    private func playWithFallbackDecoder(song: Song, url: URL, outputFormat: AVAudioFormat, playID id: UUID) async {
        guard assetReaderDecoder.canDecode(url: url) else {
            plog("⚠️ No decoder available for '\(song.title)'")
            showPlaybackError(String(localized: "playback_error_format"))
            isLoading = false
            await autoAdvanceAfterFailure()
            return
        }

        plog("↳ AVAssetReader fallback for '\(song.title)' url=\(url.scheme ?? "")://... ext=\(url.pathExtension)")

        let fallbackStream = assetReaderDecoder.decode(from: url, outputFormat: outputFormat)
        let iteratorBox = BufferIteratorBox(fallbackStream.makeAsyncIterator())

        do {
            guard let firstBuffer = try await iteratorBox.next() else {
                isLoading = false
                await autoAdvanceAfterFailure()
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
            ScrobbleService.shared.handlePlaybackStarted(song: song); PlayHistoryStore.shared.beginSession(song: song)
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
            sourceManager?.cacheInBackground(song: song, cacheEnabled: playbackSettings.audioCacheEnabled)

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
            await autoAdvanceAfterFailure()
        }
    }

    /// Schedule the final buffer of a track with the appropriate completion callback
    /// for track-end detection, respecting gapless and crossfade settings.
    private func scheduleLastBuffer(_ buffer: AVAudioPCMBuffer, playID id: UUID) {
        let settings = playbackSettings.snapshot()
        plog("📍 scheduleLastBuffer for playID=\(id.uuidString.prefix(8)) frames=\(buffer.frameLength)")

        // Standard and crossfade modes both use completion callback for track-end detection
        audioEngine.scheduleBuffer(
            buffer,
            completionCallbackType: .dataPlayedBack
        ) { [weak self] _ in
            plog("🔔 lastBuffer dataPlayedBack fired playID=\(id.uuidString.prefix(8))")
            Task { @MainActor [weak self] in
                guard let self, self.playID == id else { return }
                // In crossfade mode, only handle track end if crossfade wasn't triggered
                if settings.crossfadeEnabled && self.crossfadeTriggered { return }
                await self.handleTrackEnd()
            }
        }
    }

    /// Schedule the last decoded buffer when the stream errored mid-way.
    /// Lets the buffered audio drain so the user still hears something, but
    /// fires `autoAdvanceAfterFailure` on completion instead of
    /// `handleTrackEnd` — so repeat-one stops on a broken song instead of
    /// looping it, and the play-count isn't bumped for an aborted track.
    private func scheduleLastBufferAsFailure(_ buffer: AVAudioPCMBuffer, playID id: UUID) {
        audioEngine.scheduleBuffer(
            buffer,
            completionCallbackType: .dataPlayedBack
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.playID == id else { return }
                await self.autoAdvanceAfterFailure()
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
        guard !isLoading, let song = currentSong else { return }
        // 「已播完待重播」: 引擎已经 stopPlayback, 不能 resume —— 那是 no-op。
        // 直接重新 play 当前曲 (从 0 开始)。这是 Apple Music 锁屏在歌
        // 播完之后再点 play 的行为。
        if isAtTrackEnd {
            isAtTrackEnd = false
            Task { await play(song: song) }
            return
        }
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
        // 主动结束当前 streaming session (切走 / 用户点停止时), 让 .partial
        // 有机会转 final。
        if let cur = currentSong {
            sourceManager?.finalizeStreamingSession(for: cur)
        }
        decodingTask?.cancel()
        decodingTask = nil
        crossfadeDecodingTask?.cancel()
        crossfadeDecodingTask = nil
        crossfadeTimer?.invalidate()
        crossfadeTimer = nil
        crossfadeTriggered = false; isCrossfading = false
        audioEngine.stopPlayback()
        audioEngine.stopCrossfadeNode()
        audioEngine.resetPlayerVolume()
        isPlaying = false
        isAtTrackEnd = false
        currentSong = nil
        currentTime = 0
        duration = 0
        clearPendingPlaybackRecovery()
        stopTimeUpdater()
        ScrobbleService.shared.handlePlaybackStopped(); PlayHistoryStore.shared.endSession()
        // Clear NowPlaying info so Dynamic Island / Lock Screen also clears
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        updatePlaybackState()
    }

    /// 跟 stop() 的差别: 保留 currentSong / queue / currentIndex / duration,
    /// 只清引擎 + 标 isAtTrackEnd = true。给 handleTrackEnd .off 用 ——
    /// 用户搜出来一首歌 (queue 只有一首) 播完时不要把 UI 一下子全清掉
    /// (sheet 白屏 / mini player 闪一下消失)。用户再点 play 可以从头重放
    /// (resume() 检测到 isAtTrackEnd 会走 play(song:) 重新解码)。
    private func stopAtTrackEnd() {
        // 自然播完一首歌, 触发 finalize —— 这是 .partial → final 最关键的
        // 时机, 用户期望「听完一整首」就该是完整缓存。
        if let cur = currentSong {
            sourceManager?.finalizeStreamingSession(for: cur)
        }
        decodingTask?.cancel()
        decodingTask = nil
        crossfadeDecodingTask?.cancel()
        crossfadeDecodingTask = nil
        crossfadeTimer?.invalidate()
        crossfadeTimer = nil
        crossfadeTriggered = false; isCrossfading = false
        audioEngine.stopPlayback()
        audioEngine.stopCrossfadeNode()
        audioEngine.resetPlayerVolume()
        isPlaying = false
        isAtTrackEnd = true
        currentTime = 0
        clearPendingPlaybackRecovery()
        stopTimeUpdater()
        ScrobbleService.shared.handlePlaybackStopped(); PlayHistoryStore.shared.endSession()
        // 锁屏 / Dynamic Island 显示「停在 0:00」状态, 不清空 ——
        // 这样用户从锁屏点 play 也能直接重放当前曲。
        updateNowPlayingInfo()
        updatePlaybackState()
        plog("⏹️ stopAtTrackEnd() currentSong preserved=\(currentSong?.title ?? "nil")")
    }

    func next(caller: String = #fileID, callerLine: Int = #line) async {
        guard !queue.isEmpty else { return }
        let callerFile = (caller as NSString).lastPathComponent
        plog("⏭️ next() called FROM=\(callerFile):\(callerLine) currentIndex=\(currentIndex) queueCount=\(queue.count)")
        advanceToNextIndex()
        // 跳过相邻同 title+artist 的"重复歌曲" —— NAS 上同一首歌有多个版本
        // (mp3 + flac, 不同目录) scan 后是不同 song.id, 但用户看就是同一首,
        // 自动 next 跳到 "下一首是自己" 体验很怪。最多跳 1 次, 防止整个
        // queue 全是同一首时死循环。
        if let cur = currentSong, queue.count > 2 {
            let candidate = queue[currentIndex]
            if candidate.title == cur.title && candidate.artistName == cur.artistName {
                plog("⏭️ next: skipping duplicate '\(candidate.title)' (same title+artist as current)")
                advanceToNextIndex()
            }
        }
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
        // 用户拖进度条 = 重新介入这首歌, 退出 "已播完" 状态
        isAtTrackEnd = false
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
                let onResolveLength = makeResolveLengthCallback(for: song)
                switch activeDecoderKind {
                case .native, .streaming:
                    stream = nativeDecoder.decode(from: seekURL, outputFormat: outputFormat, onResolveSourceLength: onResolveLength)
                case .cloudStream:
                    // Build a fresh InputSource for the seek session. The
                    // sparse cache file from the prior session is reused
                    // (SFB reads will hit local for any byte range we've
                    // already fetched, fall through to network for the
                    // rest). If the song has since been fully downloaded
                    // and renamed to the canonical path, prefer that.
                    if let cached = sourceManager?.cachedURL(for: song) {
                        stream = nativeDecoder.decode(from: cached, outputFormat: outputFormat, onResolveSourceLength: onResolveLength)
                    } else if let manager = sourceManager,
                              let inputSource = try? await manager.makeStreamingInputSource(
                                  for: song,
                                  cacheEnabled: playbackSettings.audioCacheEnabled
                              ) {
                        stream = nativeDecoder.decode(from: inputSource, outputFormat: outputFormat, onResolveSourceLength: onResolveLength)
                    } else {
                        plog("⚠️ Seek: failed to build cloud streaming InputSource")
                        isLoading = false
                        return
                    }
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
        // Drop any pre-built next round — the queue itself changed, so
        // prior shuffle plans (and their indices into the old queue)
        // are stale and would index out-of-bounds on wrap.
        pendingNextShuffleIndices = nil
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
        guard var nextSong = nextSongInQueue() else {
            // No next song — use completion callback to detect track end
            scheduleEndDetection(id: id)
            return
        }

        // For repeat-one, don't gapless-chain (use normal replay via callback)
        if repeatMode == .one {
            scheduleEndDetection(id: id)
            return
        }

        // 跳过相邻同 title+artist 重复 (NAS 上同首歌的多版本)。
        // gapless 路径 bypass 了 next() 函数, 所以这里也要 dedup。
        if let cur = currentSong, queue.count > 2,
           nextSong.title == cur.title, nextSong.artistName == cur.artistName {
            plog("🔄 gaplessPreload: skip duplicate '\(nextSong.title)', advance one more")
            advanceToNextIndex()
            guard let after = nextSongInQueue() else {
                scheduleEndDetection(id: id)
                return
            }
            nextSong = after
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
            crossfadeTriggered = false; isCrossfading = false
            library?.recordPlayback(of: nextSong.id)

            // Apply ReplayGain for next track
            let settings = playbackSettings.snapshot()
            if settings.replayGainEnabled {
                await applyReplayGain(for: nextURL, mode: settings.replayGainMode)
            }

            // Decode and schedule next track's buffers (only this one track)
            guard let stream = await decodeStream(for: nextSong, url: nextURL, outputFormat: outputFormat) else {
                scheduleEndDetection(id: id)
                return
            }
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
        // Skip under repeat-one — `nextSongInQueue()` returns the
        // current song there, which would crossfade-to-self. Pre-fix
        // `currentIndex < queue.count - 1` was always false in the
        // single-song repeat-one case so crossfade was never enabled;
        // preserve that.
        guard repeatMode != .one, nextSongInQueue() != nil else { return }

        crossfadeTriggered = true
        Task { await startCrossfade(duration: settings.crossfadeDuration) }
    }

    private func startCrossfade(duration crossfadeDuration: Double) async {
        guard let nextSong = nextSongInQueue() else {
            crossfadeTriggered = false; isCrossfading = false
            return
        }

        do {
            let nextURL = try await resolvedURL(for: nextSong)
            guard nativeDecoder.canDecode(url: nextURL),
                  let outputFormat = audioEngine.outputFormat else {
                crossfadeTriggered = false; isCrossfading = false
                return
            }

            // crossfade 一开始就把 UI 切到下一首 —— 用户听到的主音是 next
            // 在淡入接管, 看到的应该跟着是 next。之前要等 ramp 跑完才切,
            // 出现「下一首歌的声音出来了但播放器还显示上一首」的不一致。
            // 期间 currentTime 暂停更新 (isCrossfading=true), 直到 swap
            // 完成跟随新 primary node。
            isCrossfading = true
            advanceToNextIndex()
            currentSong = nextSong
            currentTime = 0
            duration = nextSong.duration.sanitizedDuration
            library?.recordPlayback(of: nextSong.id)
            ScrobbleService.shared.handlePlaybackStarted(song: nextSong)
            PlayHistoryStore.shared.beginSession(song: nextSong)
            updateNowPlayingInfo()
            updateNowPlayingArtworkIfNeeded()
            updatePlaybackState()

            // Note: ReplayGain for crossfade node would need per-node volume tracking
            // For now, apply after swap

            // Decode into crossfade node — schedule first buffer before play
            guard let stream = await decodeStream(for: nextSong, url: nextURL, outputFormat: outputFormat) else {
                crossfadeTriggered = false; isCrossfading = false
                return
            }
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
            crossfadeTriggered = false; isCrossfading = false
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

        // 注意: currentSong / queue index / scrobble session 已经在
        // startCrossfade 早期设置好了, 不在这里重复 (重复会让 ScrobbleService
        // 误以为又开了一首新歌, 重新计时)。
        let newID = UUID()
        playID = newID
        crossfadeTriggered = false; isCrossfading = false
        isCrossfading = false
        plog("🔄 completeCrossfade: swap done, currentSong=\(nextSong.title)")

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
                // crossfade 期间 audioEngine 报的还是旧曲 primary node 时间,
                // 但 UI 已经切到新曲, 直接刷会让进度条乱跳。等 swap 完成
                // (isCrossfading=false) 再继续。
                if self.isCrossfading { return }
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

                    // Scrobble 进度判断 — 50% 或 4 分钟阈值由 service 内部决定。
                    // 传 currentTime (已听到这个时间点), seek 后该首歌 elapsed 视为
                    // 实际的当前 currentTime, Last.fm 协议本身允许这种近似。
                    ScrobbleService.shared.handleProgressTick(elapsed: self.currentTime); PlayHistoryStore.shared.tick(elapsed: self.currentTime)
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
            // Under shuffle, currentIndex is the queue index of the
            // currently-playing song, not the shufflePosition — so
            // comparing it to queue.count - 1 frequently passed (the
            // last shuffled song often isn't the last in original
            // order) and auto-advance kept generating fresh shuffle
            // rounds even though the user picked repeat-off.
            if nextSongInQueue() != nil {
                await next()
            } else {
                // 没下一首 —— 进 "已播完" 状态而不是 stop() 全清。
                // 否则 currentSong 一旦为 nil, 上层各种 sheet (刮削 /
                // SongInfo / AddToPlaylist) 内容是空的就白屏, mini
                // player 也闪一下消失体验很差。
                stopAtTrackEnd()
            }
        }
    }

    // MARK: - Helpers

    /// Run after a non-recoverable playback failure (unsupported format,
    /// empty stream, decode error, URL resolve fail, fallback
    /// exhausted, mid-stream decode crash). Centralises the "what
    /// happens after failure" rule so every error path stays
    /// consistent:
    /// - Under `repeatMode == .one`, `nextSongInQueue()` returns the
    ///   current song. Calling `next()` from there would either loop the
    ///   broken file forever (single-song queue) or jump to a different
    ///   track and silently violate repeat-one (multi-song queue). So
    ///   we stop and let the user see the error toast that the caller
    ///   already raised.
    /// - Otherwise advance if there's a real successor; if not (last
    ///   track failed, repeat-off), stop so the player exits the
    ///   half-broken loading/streaming state cleanly instead of
    ///   leaving the engine wedged with currentSong still set.
    private func autoAdvanceAfterFailure() async {
        if repeatMode == .one {
            stop()
            return
        }
        if nextSongInQueue() != nil {
            await next()
        } else {
            stop()
        }
    }

    private func nextSongInQueue() -> Song? {
        guard !queue.isEmpty else { return nil }

        if repeatMode == .one { return currentSong }

        if shuffleEnabled {
            let nextPos = shufflePosition + 1
            if nextPos < shuffledIndices.count {
                return queue[shuffledIndices[nextPos]]
            } else if repeatMode == .all {
                // Wrap: read the pre-generated next round (lazily built
                // here so the prefetch path and the real advance path
                // pick the SAME song — without this they'd disagree
                // because `advanceToNextIndex` reshuffles fresh and
                // we'd prewarm a completely different track).
                let pending = pendingNextShuffleIndices ?? buildPendingNextRound()
                if pendingNextShuffleIndices == nil { pendingNextShuffleIndices = pending }
                guard let firstIdx = pending.first else { return queue.first }
                return queue[firstIdx]
            } else {
                return nil
            }
        }

        let nextIndex = currentIndex + 1
        if nextIndex < queue.count {
            return queue[nextIndex]
        } else if repeatMode == .all {
            return queue[0]
        }
        return nil
    }

    private func advanceToNextIndex() {
        if shuffleEnabled {
            let nextPos = shufflePosition + 1
            if nextPos < shuffledIndices.count {
                shufflePosition = nextPos
                currentIndex = shuffledIndices[shufflePosition]
            } else {
                // End of round. Adopt the pre-generated next round
                // (built earlier by `nextSongInQueue` for prefetch) so
                // the actual track played matches what was prewarmed.
                let pending = pendingNextShuffleIndices ?? buildPendingNextRound()
                pendingNextShuffleIndices = nil
                shuffledIndices = pending
                shufflePosition = 0
                currentIndex = shuffledIndices.isEmpty ? 0 : shuffledIndices[0]
            }
        } else {
            currentIndex = (currentIndex + 1) % queue.count
        }
    }

    private func rebuildShuffleOrder() {
        guard !queue.isEmpty else { shuffledIndices = []; pendingNextShuffleIndices = nil; return }
        shuffledIndices = Array(0..<queue.count).shuffled()
        shufflePosition = 0
        pendingNextShuffleIndices = nil
        // Place current index at position 0 so current song stays first
        // when shuffle is toggled mid-playback (we don't want to jump
        // off the current track). Wrap-around uses a different builder.
        if let pos = shuffledIndices.firstIndex(of: currentIndex) {
            shuffledIndices.swapAt(0, pos)
        }
    }

    /// Build (but don't install) the next round's shuffle order. Used
    /// by both prefetch and the actual wrap so they pick the same first
    /// song. Avoids placing the just-finished track at position 0 to
    /// stop repeat-all from feeling like repeat-one at the boundary.
    private func buildPendingNextRound() -> [Int] {
        guard !queue.isEmpty else { return [] }
        var order = Array(0..<queue.count).shuffled()
        if queue.count > 1, order.first == currentIndex {
            let otherPos = Int.random(in: 1..<order.count)
            order.swapAt(0, otherPos)
        }
        return order
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
            plog("🎛️ MediaRemote nextTrackCommand fired")
            Task { await self?.next() }; return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            plog("🎛️ MediaRemote previousTrackCommand fired")
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
