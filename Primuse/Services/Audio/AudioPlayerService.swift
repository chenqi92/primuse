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

    private var currentFile: AVAudioFile?
    private var displayLink: Timer?
    private let nativeDecoder = NativeAudioDecoder()
    private var decodingTask: Task<Void, Never>?

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
        }
    }

    func play(song: Song, from url: URL) async {
        stop()
        isLoading = true
        currentSong = song
        duration = song.duration

        do {
            try audioEngine.start()

            if nativeDecoder.canDecode(url: url) {
                try await playNative(url: url)
            } else {
                // FFmpeg path - will be implemented in Phase 4
                try await playWithFFmpeg(url: url)
            }

            isPlaying = true
            isLoading = false
            startTimeUpdater()
            updateNowPlayingInfo()
            updatePlaybackState()
        } catch {
            print("Playback error: \(error)")
            isLoading = false
        }
    }

    private func playNative(url: URL) async throws {
        try audioEngine.setUp()
        guard let outputFormat = audioEngine.outputFormat else {
            throw AudioDecoderError.decodingFailed("Audio engine not ready")
        }
        let stream = nativeDecoder.decode(from: url, outputFormat: outputFormat)

        decodingTask = Task {
            do {
                for try await buffer in stream {
                    audioEngine.scheduleBuffer(buffer)
                }
                // Track finished - handle next
                await handleTrackEnd()
            } catch {
                print("Decoding error: \(error)")
            }
        }

        audioEngine.play()

        // Get accurate duration from file
        if let info = try? await nativeDecoder.fileInfo(for: url) {
            duration = info.duration
        }
    }

    private func playWithFFmpeg(url: URL) async throws {
        // Placeholder - FFmpeg decoder will be implemented in Phase 4
        throw AudioDecoderError.unsupportedFormat(url.pathExtension)
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
        if isPlaying {
            pause()
        } else {
            resume()
        }
    }

    func stop() {
        decodingTask?.cancel()
        decodingTask = nil
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
        let song = queue[currentIndex]
        await play(song: song)
    }

    func previous() async {
        guard !queue.isEmpty else { return }
        if currentTime > 3 {
            // Restart current track
            seek(to: 0)
            return
        }
        currentIndex = currentIndex > 0 ? currentIndex - 1 : queue.count - 1
        let song = queue[currentIndex]
        await play(song: song)
    }

    func seek(to time: TimeInterval) {
        currentTime = time
        // Seeking with buffer-based playback requires restarting the stream
        // from the desired position - simplified for now
        updateNowPlayingInfo()
    }

    func setQueue(_ songs: [Song], startAt index: Int = 0) {
        queue = songs
        currentIndex = min(index, songs.count - 1)
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

    // MARK: - Track End Handling

    private func handleTrackEnd() async {
        switch repeatMode {
        case .one:
            if let song = currentSong {
                await play(song: song)
            }
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

        center.playCommand.addTarget { [weak self] _ in
            self?.resume()
            return .success
        }

        center.pauseCommand.addTarget { [weak self] _ in
            self?.pause()
            return .success
        }

        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.togglePlayPause()
            return .success
        }

        center.nextTrackCommand.addTarget { [weak self] _ in
            Task { await self?.next() }
            return .success
        }

        center.previousTrackCommand.addTarget { [weak self] _ in
            Task { await self?.previous() }
            return .success
        }

        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            self?.seek(to: event.positionTime)
            return .success
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
