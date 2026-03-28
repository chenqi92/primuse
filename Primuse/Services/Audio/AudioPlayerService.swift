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
    private var decodingTask: Task<Void, Never>?
    private var playbackMonitorTask: Task<Void, Never>?

    init(sourceManager: SourceManager? = nil) {
        self.sourceManager = sourceManager
        audioEngine = AudioEngine()
        equalizerService = EqualizerService(audioEngine: audioEngine)
        setupRemoteCommands()
    }

    // MARK: - Playback Control

    func play(song: Song) async {
        do {
            let url = try await resolvedURL(for: song)
            await play(song: song, from: url)
        } catch {
            print("Playback URL resolution error: \(error)")
            isLoading = false
            // Skip to next on error
            await next()
        }
    }

    func play(song: Song, from url: URL) async {
        stop()
        isLoading = true
        currentSong = song
        duration = song.duration

        // Check if native decoder can handle this format
        guard nativeDecoder.canDecode(url: url) else {
            print("Unsupported format: \(url.pathExtension)")
            isLoading = false
            // Skip unsupported formats
            if currentIndex < queue.count - 1 {
                await next()
            }
            return
        }

        do {
            try audioEngine.setUp()
            guard let outputFormat = audioEngine.outputFormat else {
                throw AudioDecoderError.decodingFailed("Audio engine not ready")
            }

            try audioEngine.start()

            // Get accurate duration from file BEFORE starting playback
            if let info = try? await nativeDecoder.fileInfo(for: url) {
                duration = info.duration
            }

            // Decode and schedule all buffers
            let stream = nativeDecoder.decode(from: url, outputFormat: outputFormat)

            decodingTask = Task {
                do {
                    var bufferCount = 0
                    for try await buffer in stream {
                        guard !Task.isCancelled else { return }
                        audioEngine.scheduleBuffer(buffer)
                        bufferCount += 1

                        // Start playback after first buffer
                        if bufferCount == 1 {
                            audioEngine.play()
                        }
                    }
                    // All buffers scheduled — DON'T call handleTrackEnd here!
                    // Instead, monitor when playback actually finishes
                } catch {
                    if !Task.isCancelled {
                        print("Decoding error: \(error)")
                    }
                }
            }

            isPlaying = true
            isLoading = false
            startTimeUpdater()
            startPlaybackMonitor()
            updateNowPlayingInfo()
            updatePlaybackState()
        } catch {
            print("Playback error: \(error)")
            isLoading = false
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
        playbackMonitorTask?.cancel()
        playbackMonitorTask = nil
        audioEngine.stopPlayback()
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

    func seek(to time: TimeInterval) {
        currentTime = time
        updateNowPlayingInfo()
    }

    func setQueue(_ songs: [Song], startAt index: Int = 0) {
        queue = songs
        currentIndex = min(index, songs.count - 1)
    }

    // MARK: - Playback Monitor (detect when playback truly finishes)

    private func startPlaybackMonitor() {
        playbackMonitorTask?.cancel()
        playbackMonitorTask = Task {
            // Wait for decoding to finish first
            while decodingTask != nil && !decodingTask!.isCancelled {
                if decodingTask!.isCancelled { return }
                try? await Task.sleep(for: .milliseconds(500))
            }

            // Now wait for the audio engine to finish playing all scheduled buffers
            // Check periodically if playback position has stopped advancing
            var lastTime: TimeInterval = -1
            var staleCount = 0

            while !Task.isCancelled && isPlaying {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }

                let current = audioEngine.currentTime ?? 0

                // If time stopped advancing and we're near the end
                if abs(current - lastTime) < 0.1 && current > 0 {
                    staleCount += 1
                    if staleCount >= 2 {
                        // Playback truly finished
                        await handleTrackEnd()
                        return
                    }
                } else {
                    staleCount = 0
                }
                lastTime = current
            }
        }
    }

    // MARK: - Time Updates

    private func startTimeUpdater() {
        stopTimeUpdater()
        displayLink = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            if let time = self.audioEngine.currentTime {
                self.currentTime = time
            }
        }
    }

    private func stopTimeUpdater() {
        displayLink?.invalidate()
        displayLink = nil
    }

    // MARK: - Track End

    private func handleTrackEnd() async {
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
