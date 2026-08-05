@preconcurrency import AVFoundation
import Foundation
import PrimuseKit

private struct RadioMetadataItemBox: @unchecked Sendable {
    let item: AVMetadataItem
}

@MainActor
final class RadioPlaybackController: NSObject {
    enum Event: Sendable {
        case loading
        case ready(format: RadioStreamFormat, bitRate: Int?)
        case playing
        case buffering
        case metadata(title: String)
        case failed(message: String, shouldReconnect: Bool)
    }

    private(set) var player: AVPlayer?
    private var item: AVPlayerItem?
    private var eventHandler: ((Event) -> Void)?
    private var playerStatusObservation: NSKeyValueObservation?
    private var itemStatusObservation: NSKeyValueObservation?
    private var accessLogObserver: NSObjectProtocol?
    private var stalledObserver: NSObjectProtocol?
    private var failedObserver: NSObjectProtocol?
    private var endedObserver: NSObjectProtocol?
    private var metadataOutput: AVPlayerItemMetadataOutput?
    private var stationURL: URL?
    private var inferredFormat: RadioStreamFormat = .automatic
    private var generation = UUID()
    private var terminalFailureDelivered = false

    func start(url: URL, volume: Float, eventHandler: @escaping (Event) -> Void) {
        stop()
        let generation = UUID()
        self.generation = generation
        self.eventHandler = eventHandler
        self.stationURL = url
        self.inferredFormat = RadioStreamFormat.inferred(from: url)
        terminalFailureDelivered = false
        eventHandler(.loading)

        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 3
        item.canUseNetworkResourcesForLiveStreamingWhilePaused = false

        let metadataOutput = AVPlayerItemMetadataOutput(identifiers: nil)
        metadataOutput.setDelegate(self, queue: .main)
        item.add(metadataOutput)
        self.metadataOutput = metadataOutput
        self.item = item

        let player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = true
        player.volume = volume
        self.player = player

        itemStatusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == generation else { return }
                switch item.status {
                case .readyToPlay:
                    self.publishReadyState()
                case .failed:
                    self.publishFailure(item.error, shouldReconnect: false)
                case .unknown:
                    break
                @unknown default:
                    break
                }
            }
        }
        playerStatusObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == generation else { return }
                switch player.timeControlStatus {
                case .playing: self.eventHandler?(.playing)
                case .waitingToPlayAtSpecifiedRate: self.eventHandler?(.buffering)
                case .paused: break
                @unknown default: break
                }
            }
        }

        let center = NotificationCenter.default
        accessLogObserver = center.addObserver(
            forName: .AVPlayerItemNewAccessLogEntry,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == generation else { return }
                self.publishReadyState()
            }
        }
        stalledObserver = center.addObserver(
            forName: .AVPlayerItemPlaybackStalled,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == generation else { return }
                self.eventHandler?(.buffering)
            }
        }
        failedObserver = center.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] note in
            let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            Task { @MainActor [weak self] in
                guard let self, self.generation == generation else { return }
                self.publishFailure(error, shouldReconnect: true)
            }
        }
        endedObserver = center.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == generation else { return }
                self.publishFailure(nil, shouldReconnect: true)
            }
        }

        player.play()
    }

    func stop() {
        generation = UUID()
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        item = nil
        metadataOutput = nil
        eventHandler = nil
        stationURL = nil
        playerStatusObservation = nil
        itemStatusObservation = nil
        for observer in [accessLogObserver, stalledObserver, failedObserver, endedObserver] {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
        accessLogObserver = nil
        stalledObserver = nil
        failedObserver = nil
        endedObserver = nil
    }

    func setVolume(_ value: Float) {
        player?.volume = min(max(value, 0), 1)
    }

    private func publishReadyState() {
        guard let item else { return }
        let event = item.accessLog()?.events.last
        let bitsPerSecond = event.map { max($0.observedBitrate, $0.indicatedBitrate) }
        let bitRate = bitsPerSecond.flatMap { value -> Int? in
            guard value.isFinite, value > 0 else { return nil }
            return Int(value.rounded())
        }
        eventHandler?(.ready(format: inferredFormat, bitRate: bitRate))
    }

    private func publishFailure(_ error: Error?, shouldReconnect: Bool) {
        guard !terminalFailureDelivered else { return }
        terminalFailureDelivered = true
        let message = error?.localizedDescription ?? String(localized: "radio_stream_ended")
        eventHandler?(.failed(message: message, shouldReconnect: shouldReconnect))
    }

    static func probe(url: URL, timeout: Duration = .seconds(12)) async -> Result<Void, Error> {
        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = true
        player.isMuted = true
        player.play()
        defer {
            player.pause()
            player.replaceCurrentItem(with: nil)
        }

        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if item.status == .readyToPlay {
                return .success(())
            }
            if item.status == .failed {
                return .failure(item.error ?? URLError(.cannotDecodeContentData))
            }
            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                return .failure(error)
            }
        }
        return .failure(URLError(.timedOut))
    }
}

extension RadioPlaybackController: AVPlayerItemMetadataOutputPushDelegate {
    nonisolated func metadataOutput(
        _ output: AVPlayerItemMetadataOutput,
        didOutputTimedMetadataGroups groups: [AVTimedMetadataGroup],
        from track: AVPlayerItemTrack?
    ) {
        let titleItems = groups.flatMap(\.items)
            .filter(Self.isTitleMetadata)
            .map(RadioMetadataItemBox.init)
        guard !titleItems.isEmpty else { return }
        Task { @MainActor [weak self] in
            for itemBox in titleItems.reversed() {
                guard let rawValue = try? await itemBox.item.load(.stringValue) else { continue }
                let title = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty else { continue }
                self?.eventHandler?(.metadata(title: title))
                return
            }
        }
    }

    nonisolated private static func isTitleMetadata(_ item: AVMetadataItem) -> Bool {
        let key = (item.key.map { String(describing: $0) } ?? "").lowercased()
        let commonKey = item.commonKey?.rawValue.lowercased() ?? ""
        return key.contains("title") || key.contains("streamtitle") || commonKey == "title"
    }
}
