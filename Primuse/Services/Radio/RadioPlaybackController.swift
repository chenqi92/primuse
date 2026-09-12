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
        case metadata(RadioLiveMetadata)
        /// 这条流带了字幕轨。绝大多数广播电台不会走到这里。
        case subtitleTracks([RadioSubtitleTrack])
        /// 当前该显示的字幕文本；`nil` 表示这一刻没有字幕。
        case subtitle(String?)
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
    private var legibleOutput: AVPlayerItemLegibleOutput?
    private var subtitleGroup: AVMediaSelectionGroup?
    private var didInspectSubtitles = false
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
                    self.inspectSubtitleTracksIfNeeded(generation: generation)
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
        legibleOutput = nil
        subtitleGroup = nil
        didInspectSubtitles = false
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
    /// 系统会把 Shoutcast 的 ICY 元数据(以及 HLS 分片里的 ID3)翻译成
    /// timed metadata 推过来。除了曲名，有些电台还会带一个 `StreamUrl` ——
    /// 那通常是当前曲目或电台的配图，值得一并取出来。
    nonisolated func metadataOutput(
        _ output: AVPlayerItemMetadataOutput,
        didOutputTimedMetadataGroups groups: [AVTimedMetadataGroup],
        from track: AVPlayerItemTrack?
    ) {
        let items = groups.flatMap(\.items).map(RadioMetadataItemBox.init)
        guard !items.isEmpty else { return }

        Task { @MainActor [weak self] in
            var title: String?
            var artworkURL: String?

            for box in items {
                let kind = Self.kind(of: box.item)
                guard kind != .other else { continue }
                guard let raw = try? await box.item.load(.stringValue) else { continue }
                let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty else { continue }
                switch kind {
                case .title:
                    // 一个 group 里可能有好几条，后来的更新，取最后一条非空的。
                    title = value
                case .streamURL:
                    artworkURL = value
                case .other:
                    break
                }
            }

            // `StreamUrl` 在协议里既可能是图片也可能是电台主页，交给统一的
            // 判定来分流，不在这里猜。
            let icy = RadioICYMetadata(
                streamTitle: title,
                artworkURL: RadioLogoURLPolicy.looksLikeBitmap(artworkURL)
                    ? RadioLogoURLPolicy.normalized(artworkURL)
                    : nil,
                homepageURL: RadioLogoURLPolicy.looksLikeBitmap(artworkURL)
                    ? nil
                    : RadioLogoURLPolicy.normalized(artworkURL)
            )
            let metadata = RadioLiveMetadata(icy: icy)
            guard !metadata.isEmpty else { return }
            self?.eventHandler?(.metadata(metadata))
        }
    }

    private enum MetadataKind {
        case title
        case streamURL
        case other
    }

    nonisolated private static func kind(of item: AVMetadataItem) -> MetadataKind {
        let key = (item.key.map { String(describing: $0) } ?? "").lowercased()
        let identifier = item.identifier?.rawValue.lowercased() ?? ""
        let commonKey = item.commonKey?.rawValue.lowercased() ?? ""

        if key.contains("streamurl") || identifier.contains("streamurl") {
            return .streamURL
        }
        if key.contains("title") || commonKey == "title" || identifier.contains("title") {
            return .title
        }
        return .other
    }
}

// MARK: - 字幕轨

extension RadioPlaybackController {
    /// 探一次这条流有没有字幕轨。
    ///
    /// 实测广播电台基本不带字幕(2026-09 抽样的 13 个 HLS 电台无一例外)，
    /// 所以这里的策略是「先看有没有，有才挂输出」：没有字幕轨的流一个额外
    /// 对象都不会创建，播放路径完全不受影响。
    func inspectSubtitleTracksIfNeeded(generation: UUID) {
        guard !didInspectSubtitles, let item else { return }
        didInspectSubtitles = true
        let asset = item.asset

        Task { @MainActor [weak self] in
            let group = try? await asset.loadMediaSelectionGroup(for: .legible)
            guard let group, !group.options.isEmpty else { return }
            guard let self,
                  self.generation == generation,
                  let currentItem = self.item else { return }

            self.subtitleGroup = group
            let output = AVPlayerItemLegibleOutput()
            // 播放页自己画字幕，不让系统再渲染一层。
            output.suppressesPlayerRendering = true
            output.setDelegate(self, queue: .main)
            currentItem.add(output)
            self.legibleOutput = output

            let tracks = group.options.enumerated().map { index, option in
                RadioSubtitleTrack(
                    id: String(index),
                    displayName: option.displayName,
                    languageCode: option.extendedLanguageTag
                        ?? option.locale?.identifier
                )
            }
            self.eventHandler?(.subtitleTracks(tracks))
        }
    }

    /// 选一条字幕轨；传 `nil` 关闭字幕。
    func selectSubtitleTrack(id: String?) {
        guard let item, let group = subtitleGroup else { return }
        guard let id, let index = Int(id), group.options.indices.contains(index) else {
            item.select(nil, in: group)
            eventHandler?(.subtitle(nil))
            return
        }
        item.select(group.options[index], in: group)
    }
}

extension RadioPlaybackController: AVPlayerItemLegibleOutputPushDelegate {
    nonisolated func legibleOutput(
        _ output: AVPlayerItemLegibleOutput,
        didOutputAttributedStrings strings: [NSAttributedString],
        nativeSampleBuffers: [Any],
        forItemTime itemTime: CMTime
    ) {
        // NSAttributedString 不是 Sendable，先在这里落成纯文本再跨隔离域。
        let text = strings
            .map(\.string)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let payload = text.isEmpty ? nil : text
        Task { @MainActor [weak self] in
            self?.eventHandler?(.subtitle(payload))
        }
    }
}
