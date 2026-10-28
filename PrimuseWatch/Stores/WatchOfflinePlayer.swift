import AVFoundation
import MediaPlayer
import Observation
import WatchKit
import ImageIO

@MainActor @Observable
final class WatchOfflinePlayer: NSObject, AVAudioPlayerDelegate {
    private(set) var current: WatchOfflineFile?
    private(set) var queue: [WatchOfflineFile] = []
    private(set) var isLoading = false
    private(set) var error: String?
    var mode: WatchPlaybackMode = .sequential
    var onChange: (() -> Void)?
    private(set) var cover: UIImage?
    private(set) var lyrics: [WatchOfflineLyric] = []
    private var player: AVAudioPlayer?
    private var playTask: Task<Void, Never>?
    private var interruptionObserver: NSObjectProtocol?
    private var routeObserver: NSObjectProtocol?
    private var volumeObserver: NSKeyValueObservation?
    var onVolumeChange: (() -> Void)?
    private var resumeAfterInterruption = false
    private var storage: WatchOfflineStorage?
    private var generation = UUID()

    var isPlaying: Bool { player?.isPlaying == true }
    var currentTime: TimeInterval { player?.currentTime ?? 0 }
    var duration: TimeInterval { player?.duration ?? 0 }

    override init() {
        super.init()
        interruptionObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification,
                                                                       object: nil, queue: .main) { [weak self] note in
            let kind = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) ?? 0
            let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt) ?? 0
            Task { @MainActor in self?.interrupted(kind: kind, options: options) }
        }
        routeObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification,
                                                               object: nil, queue: .main) { [weak self] note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt) ?? 0
            Task { @MainActor in
                guard let self, self.current != nil else { return }
                if reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue { self.pause() }
                self.onChange?()
            }
        }
        volumeObserver = AVAudioSession.sharedInstance().observe(\.outputVolume, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in
                guard self?.current != nil else { return }
                self?.onVolumeChange?()
            }
        }
        registerRemoteCommands()
    }

    func play(_ track: WatchOfflineFile, in queue: [WatchOfflineFile], storage: WatchOfflineStorage) {
        playTask?.cancel()
        generation = UUID()
        let token = generation
        self.storage = storage
        self.queue = queue
        player?.stop()
        player = nil
        current = track
        cover = nil
        lyrics = []
        error = nil
        isLoading = true
        onChange?()
        playTask = Task { [weak self] in
            guard let self else { return }
            do {
                let url = try storage.resolve(track.path)
                let audio = try AVAudioPlayer(contentsOf: url)
                audio.delegate = self
                audio.prepareToPlay()
                self.player = audio
                self.reloadCompanions()
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playback, mode: .default, policy: .longFormAudio, options: [])
                try await session.activate()
                guard !Task.isCancelled, self.generation == token else { return }
                guard audio.play() else { throw CocoaError(.fileReadCorruptFile) }
                self.isLoading = false
                self.playTask = nil
                self.publish()
            } catch {
                guard !Task.isCancelled, self.generation == token else { return }
                self.isLoading = false
                self.playTask = nil
                self.error = WatchString("ext.watch.offline.playFailed") + "\n" + error.localizedDescription
                self.publish()
            }
        }
    }

    func toggle() {
        guard let current, let storage else { return }
        if isPlaying || isLoading { pause(); return }
        if player == nil { play(current, in: queue, storage: storage); return }
        activateAndResume()
    }

    private func activateAndResume() {
        playTask?.cancel()
        let token = UUID(); generation = token
        isLoading = true; onChange?()
        playTask = Task { [weak self] in
            do {
                try await AVAudioSession.sharedInstance().activate()
                guard !Task.isCancelled, let self, self.generation == token else { return }
                guard self.player?.play() == true else { throw CocoaError(.fileReadCorruptFile) }
                self.isLoading = false; self.playTask = nil; self.publish()
            } catch {
                guard !Task.isCancelled, let self, self.generation == token else { return }
                self.isLoading = false; self.playTask = nil
                self.error = error.localizedDescription; self.publish()
            }
        }
    }

    func pause() {
        generation = UUID(); playTask?.cancel(); playTask = nil
        player?.pause(); isLoading = false; resumeAfterInterruption = false
        publish()
    }

    func seek(_ time: TimeInterval) {
        guard time.isFinite else { return }
        player?.currentTime = min(max(0, time), duration)
        publish()
    }

    func advance(backwards: Bool = false, automatically: Bool = false) {
        guard let current, let storage, let index = queue.firstIndex(where: { $0.id == current.id }), !queue.isEmpty else { return }
        if automatically, mode == .repeatOne { seek(0); activateAndResume(); return }
        if backwards, currentTime > 3 { seek(0); return }
        let next: Int
        if mode == .shuffle, queue.count > 1 {
            next = queue.indices.filter { $0 != index }.randomElement() ?? index
        } else {
            next = index + (backwards ? -1 : 1)
        }
        if next >= queue.count, mode == .sequential {
            pause(); seek(duration); return
        }
        play(queue[(next + queue.count) % queue.count], in: queue, storage: storage)
    }

    func stop() {
        generation = UUID(); playTask?.cancel(); playTask = nil
        player?.stop(); player = nil; current = nil; isLoading = false
        lyrics = []; cover = nil; error = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func clearError() { error = nil }

    func reloadCompanions() {
        guard let current, let storage else { return }
        cover = nil
        lyrics = []
        if let url = storage.companionURL(for: current.path, extensions: ["jpg", "jpeg", "png", "heic", "webp"]) {
            cover = Self.thumbnail(at: url)
        }
        if let url = storage.companionURL(for: current.path, extensions: ["watchlyrics"]),
           let data = try? Data(contentsOf: url), data.count <= 8 * 1024 * 1024,
           let decoded = try? JSONDecoder().decode([WatchOfflineLyric].self, from: data) {
            lyrics = decoded.filter { $0.time.isFinite && $0.time >= 0 }.sorted { $0.time < $1.time }
        }
        publish()
    }

    static func thumbnail(at url: URL) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 400,
              ] as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }

    func updateQueue(_ files: [WatchOfflineFile]) { queue = files; publish() }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            guard self.player === player else { return }
            if flag { self.advance(automatically: true) }
            else { self.error = WatchString("ext.watch.offline.playFailed"); self.pause() }
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        let detail = error?.localizedDescription
        Task { @MainActor in
            guard self.player === player else { return }
            self.error = detail ?? WatchString("ext.watch.offline.playFailed")
            self.pause()
        }
    }

    private func interrupted(kind: UInt, options: UInt) {
        guard current != nil else { return }
        if kind == AVAudioSession.InterruptionType.began.rawValue {
            let resume = isPlaying
            pause(); resumeAfterInterruption = resume
        } else if resumeAfterInterruption, AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume) {
            resumeAfterInterruption = false; activateAndResume()
        }
    }

    private func publish() {
        if let current {
            var info: [String: Any] = [MPMediaItemPropertyTitle: current.title,
                                      MPMediaItemPropertyArtist: current.artist,
                                      MPMediaItemPropertyPlaybackDuration: duration,
                                      MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
                                      MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0]
            if let cover { info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: cover.size) { _ in cover } }
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        }
        onChange?()
    }

    private func registerRemoteCommands() {
        let commands = MPRemoteCommandCenter.shared()
        for command in [commands.playCommand, commands.pauseCommand, commands.togglePlayPauseCommand,
                        commands.nextTrackCommand, commands.previousTrackCommand] { command.isEnabled = true }
        commands.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in if self?.isPlaying == false { self?.toggle() } }; return .success
        }
        commands.pauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.pause() }; return .success }
        commands.togglePlayPauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.toggle() }; return .success }
        commands.nextTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.advance() }; return .success }
        commands.previousTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.advance(backwards: true) }; return .success }
        commands.changePlaybackPositionCommand.isEnabled = true
        commands.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let position = event.positionTime
            Task { @MainActor in self?.seek(position) }; return .success
        }
    }
}
