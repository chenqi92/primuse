#if os(tvOS)
import Foundation
import PrimuseKit

/// Two silent, pre-seeked decks share the store's transport and audio session.
/// Only the audible selection publishes metadata; preparing a successor cannot
/// overwrite the current song, lyrics, system controls or library duration.
@MainActor
final class TVMedleyPlayback {
    @MainActor private final class Deck {
        let engine = TVAudioEngine(managesSystemPlayback: false)
        let coordinator: TVPlaybackCoordinator
        var song: Song?
        var task: Task<Void, Never>?
        var ready = false
        var failure: String?

        init(store: TVStore) {
            coordinator = TVPlaybackCoordinator(store: store, engine: engine, publishesPresentation: false)
        }

        func reset() {
            task?.cancel()
            task = nil
            coordinator.cancelAuxiliaryTasks()
            engine.stop()
            engine.setMixVolume(0)
            ready = false
            failure = nil
            song = nil
        }
    }

    private weak var store: TVStore?
    private let facade: TVAudioEngine
    private let requestID: UUID
    private let decks: [Deck]
    private var active = 0
    private var outgoing: Int?
    private var fadeDuration: Double = 0
    private var fadeElapsed: Double = 0
    private var monitor: Task<Void, Never>?
    private var wantsPlaying = true
    private var stopped = false
    private var failedIDs: Set<String> = []
    private let nextSong: (String, Set<String>) -> Song?
    private let selected: (Song) -> Void

    init(store: TVStore, requestID: UUID,
         nextSong: @escaping (String, Set<String>) -> Song?, selected: @escaping (Song) -> Void) {
        self.store = store
        facade = store.engine
        self.requestID = requestID
        decks = [Deck(store: store), Deck(store: store)]
        self.nextSong = nextSong
        self.selected = selected
    }

    func start(_ song: Song, at time: Double = 0, autoPlay: Bool = true) {
        wantsPlaying = autoPlay
        facade.beginExternalPlayback(duration: song.duration, transport: .init(
            pause: { [weak self] in self?.pause() },
            resume: { [weak self] in self?.resume() },
            seek: { [weak self] in self?.seek(to: $0) },
            stop: { [weak self] in self?.stop() }
        ), ownsAudioSession: true)
        prepare(song, in: active, at: time)
        monitor = Task { [weak self] in
            var previous = ProcessInfo.processInfo.systemUptime
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard !Task.isCancelled, let self, !self.stopped else { return }
                let now = ProcessInfo.processInfo.systemUptime
                self.tick(delta: min(0.2, max(0, now - previous)))
                previous = now
            }
        }
    }

    private func prepare(_ song: Song, in index: Int, at time: Double = 0) {
        let deck = decks[index]
        deck.reset()
        deck.song = song
        deck.engine.prepareForSelection(startAt: time)
        deck.task = Task { [weak self, weak deck] in
            guard let self, let deck else { return }
            await deck.coordinator.play(songID: song.id, requestID: self.requestID,
                                        startAt: time, autoPlay: false, playbackSongOverride: song)
            let deadline = ProcessInfo.processInfo.systemUptime + 30
            while !Task.isCancelled, !self.stopped {
                if case .failed(let message) = deck.engine.status {
                    deck.failure = message
                    return
                }
                if deck.engine.isReadyForPreparedPlayback {
                    deck.ready = true
                    return
                }
                if ProcessInfo.processInfo.systemUptime >= deadline {
                    deck.failure = PMString("ext.tv.playback.failed")
                    return
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    private func tick(delta: Double) {
        guard let store, store.isCurrentPlaybackRequest(requestID, isCancelled: false),
              let song = decks[active].song else { stop(); return }
        let current = decks[active]
        if case .failed(let message) = current.engine.status { current.failure = message }
        if let failure = current.failure {
            failedIDs.insert(song.id)
            if let successor = nextSong(song.id, failedIDs) {
                decks[1 - active].reset()
                outgoing = nil
                selected(successor)
                prepare(successor, in: active)
            } else {
                facade.pause()
                stop()
                facade.failExternalPlayback(failure)
                store.playbackIssue = .failed(failure)
            }
            return
        }
        if current.ready, wantsPlaying, current.engine.status == .paused,
           current.engine.currentTime < max(0, current.engine.duration - 0.05) {
            current.engine.setMixVolume(outgoing == nil ? 1 : 0)
            _ = current.engine.play()
        }
        current.engine.setSpectrumAnalysisEnabled(facade.wantsSpectrumAnalysis)

        if let outgoing {
            if wantsPlaying, current.engine.isPlaying { fadeElapsed += delta }
            let progress = min(1, fadeElapsed / max(0.01, fadeDuration))
            current.engine.setMixVolume(Float(sin(progress * .pi / 2)))
            decks[outgoing].engine.setMixVolume(Float(cos(progress * .pi / 2)))
            if progress >= 1 || !decks[outgoing].engine.isPlaying && wantsPlaying {
                decks[outgoing].reset()
                self.outgoing = nil
                current.engine.setMixVolume(1)
            }
        } else if current.ready {
            let standby = 1 - active
            if let prepared = decks[standby].song,
               nextSong(song.id, failedIDs)?.id != prepared.id {
                decks[standby].reset()
            }
            if case .failed(let message) = decks[standby].engine.status { decks[standby].failure = message }
            if decks[standby].failure != nil, let failed = decks[standby].song {
                failedIDs.insert(failed.id)
                decks[standby].reset()
            }
            if decks[standby].song == nil, let successor = nextSong(song.id, failedIDs) {
                prepare(successor, in: standby)
            }
            let remaining = max(0, current.engine.duration - current.engine.currentTime)
            if wantsPlaying, remaining <= MedleySegmentPolicy.overlap(segmentLength: song.duration),
               decks[standby].ready, let successor = decks[standby].song {
                outgoing = active
                active = standby
                fadeDuration = min(remaining, MedleySegmentPolicy.overlap(segmentLength: successor.duration))
                fadeElapsed = 0
                decks[active].engine.setMixVolume(0)
                _ = decks[active].engine.play()
                selected(successor)
            }
        }
        let audible = decks[active]
        if audible.ready, wantsPlaying, !audible.engine.isPlaying,
           audible.engine.currentTime >= audible.engine.duration - 0.05,
           decks[1 - active].song == nil, outgoing == nil {
            facade.pause()
        }
        let waitingForNext = audible.ready && wantsPlaying && !audible.engine.isPlaying
            && audible.engine.currentTime >= audible.engine.duration - 0.05
            && decks[1 - active].song != nil && outgoing == nil
        let status: TVAudioEngine.Status = !audible.ready || waitingForNext
            ? (wantsPlaying ? .loading : .paused) : audible.engine.status
        facade.downloadProgress = audible.engine.downloadProgress
        facade.updateExternalPlayback(currentTime: audible.engine.interpolatedTime(),
                                      duration: audible.song?.duration,
                                      isPlaying: audible.engine.isPlaying,
                                      status: status, spectrum: audible.engine.spectrumLevels)
    }

    func invalidateSuccessor() {
        guard outgoing == nil else { return }
        decks[1 - active].reset()
        failedIDs = []
    }

    private func pause() {
        wantsPlaying = false
        if decks[active].ready { decks[active].engine.pause() }
        if let outgoing { decks[outgoing].engine.pause() }
    }

    private func resume() {
        wantsPlaying = true
        let current = decks[active]
        if current.ready {
            if current.engine.currentTime >= current.engine.duration - 0.05, let song = current.song {
                prepare(song, in: active)
                return
            }
            _ = current.engine.play()
        }
        if let outgoing { _ = decks[outgoing].engine.play() }
    }

    private func seek(to time: Double) {
        if let outgoing { decks[outgoing].reset(); self.outgoing = nil }
        if !decks[active].ready, let song = decks[active].song {
            prepare(song, in: active, at: time)
            return
        }
        decks[active].engine.setMixVolume(1)
        decks[active].engine.seek(to: time)
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        monitor?.cancel()
        monitor = nil
        for deck in decks {
            deck.reset()
            deck.engine.releaseAuxiliaryPlayback()
        }
    }
}
#endif
