import AVFoundation
import CryptoKit
import Foundation
import MediaPlayer
import PrimuseKit
import SFBAudioEngine
#if os(iOS)
import UIKit
import WidgetKit
#elseif os(macOS)
import AppKit
import ImageIO
import UniformTypeIdentifiers
import WidgetKit
#endif

#if os(iOS)
extension Notification.Name {
    static let primuseCarPlaySceneDidConnect = Notification.Name("primuse.carPlaySceneDidConnect")
    static let primuseCarPlaySceneDidDisconnect = Notification.Name("primuse.carPlaySceneDidDisconnect")
}
#endif

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
    private var iterator: AudioBufferStream.AsyncIterator

    init(_ iterator: AudioBufferStream.AsyncIterator) {
        self.iterator = iterator
    }

    func next() async throws -> AVAudioPCMBuffer? {
        try await iterator.next()
    }
}

/// Async backpressure gate bounding the duration and count of decoded PCM
/// buffers that are scheduled-but-not-yet-consumed on an `AVAudioPlayerNode`.
///
/// Without this, `NativeAudioDecoder` yields buffers far faster than realtime
/// playback and the whole track (plus the gapless next track) ends up resident
/// in the node's unbounded queue — hundreds of MB for hi-res long tracks, which
/// trips iOS jetsam during background playback.
///
/// `acquire()` suspends the decoder when the duration or hard count limit is reached;
/// `release()` (called from the node's `.dataConsumed` completion handler, which
/// also fires on `reset()`/`stop()`) wakes the next waiter so decoding paces to
/// playback.
private actor AsyncBufferGate {
    private struct Waiter {
        let duration: TimeInterval
        let continuation: CheckedContinuation<Void, Never>
    }

    private let maxBufferedDuration: TimeInterval
    private let maxBufferCount: Int
    private var inFlightDuration: TimeInterval = 0
    private var inFlightCount = 0
    private var waiters: [Waiter] = []

    init(maxBufferedDuration: TimeInterval, maxBufferCount: Int) {
        self.maxBufferedDuration = max(0.1, maxBufferedDuration)
        self.maxBufferCount = max(1, maxBufferCount)
    }

    func acquire(duration: TimeInterval) async {
        let normalizedDuration = Self.normalized(duration)
        if canAdmit(duration: normalizedDuration) {
            reserve(duration: normalizedDuration)
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(Waiter(duration: normalizedDuration, continuation: continuation))
        }
    }

    /// Non-suspending counterpart to `acquire()`, callable from `@Sendable`
    /// completion handlers without awaiting.
    nonisolated func release(duration: TimeInterval) {
        Task { await self.signal(releasing: Self.normalized(duration)) }
    }

    private nonisolated static func normalized(_ duration: TimeInterval) -> TimeInterval {
        guard duration.isFinite, duration > 0 else { return 0 }
        return duration
    }

    private func canAdmit(duration: TimeInterval) -> Bool {
        guard inFlightCount < maxBufferCount else { return false }
        // A single unusually large buffer must still be admitted or the gate
        // would deadlock before scheduling it.
        return inFlightCount == 0 || inFlightDuration + duration <= maxBufferedDuration
    }

    private func reserve(duration: TimeInterval) {
        inFlightCount += 1
        inFlightDuration += duration
    }

    private func signal(releasing duration: TimeInterval) {
        if inFlightCount > 0 {
            inFlightCount -= 1
            inFlightDuration = max(0, inFlightDuration - duration)
        }

        while let waiter = waiters.first, canAdmit(duration: waiter.duration) {
            waiters.removeFirst()
            reserve(duration: waiter.duration)
            waiter.continuation.resume()
        }
    }

    /// Wakes every waiter so a cancelled decoder loop never deadlocks on the
    /// gate even if some `.dataConsumed` callbacks were dropped.
    func drain() {
        let pending = waiters
        waiters.removeAll()
        inFlightCount = 0
        inFlightDuration = 0
        for waiter in pending {
            waiter.continuation.resume()
        }
    }
}

/// Result carrier used by the first-buffer timeout task group.
private struct PCMBufferBox: @unchecked Sendable {
    let value: AVAudioPCMBuffer?
}

/// Mutable handoff state for one gapless boundary. The audio scheduling
/// callback and decoder task both touch it, but all mutations are routed
/// back through `AudioPlayerService` on MainActor.
private final class GaplessTransitionState: @unchecked Sendable {
    let queueGeneration: Int
    var prepared: GaplessPreparedTrack?
    var didBoundaryFire = false
    var shouldCancelPreparation = false
    var isFullyScheduled = false
    var didFail = false

    init(queueGeneration: Int) {
        self.queueGeneration = queueGeneration
    }
}

private struct GaplessPreparedTrack: @unchecked Sendable {
    let song: Song
    let url: URL
    let decoderKind: AudioPlayerService.DecoderKind
    let followingTransition: GaplessTransitionState
}

/// One slot in the play queue. Wraps a `Song` with a per-slot UUID so
/// the queue can hold the same song multiple times without ID
/// collisions in SwiftUI ForEach. The id stays put across metadata
/// backfill (`syncSongMetadata` only mutates `song`), so list rows
/// don't lose their identity when the embedded song's tags get
/// rewritten by a later scan.
struct QueueEntry: Sendable, Identifiable {
    let id: UUID
    var song: Song

    init(song: Song, id: UUID = UUID()) {
        self.id = id
        self.song = song
    }
}

/// One visible occurrence of a queue slot. Repeat-all may show the same slot in
/// both the current and next shuffle rounds, so the presentation identity also
/// carries a round offset instead of reusing `QueueEntry.id` by itself.
struct QueuePresentationEntry: Sendable, Identifiable {
    struct ID: Hashable, Sendable {
        let queueEntryID: UUID
        let roundOffset: Int
    }

    let id: ID
    let entry: QueueEntry

    init(entry: QueueEntry, roundOffset: Int) {
        self.id = ID(queueEntryID: entry.id, roundOffset: roundOffset)
        self.entry = entry
    }
}

#if os(macOS)
/// Immutable snapshot handed off by `AudioPlayerService` whenever playback
/// changes. App Group and image I/O must never run on the main actor: a stalled
/// shared-container write would otherwise freeze the complete macOS UI while
/// audio continues in the background.
private struct MacWidgetPlaybackPublishRequest: Sendable {
    let currentSong: Song?
    let isPlaying: Bool
    let currentTime: TimeInterval
    let duration: TimeInterval
    let queueSongIDs: [String]
}

/// Serial, latest-wins widget publisher for macOS.
///
/// The detached worker owns every potentially blocking App Group operation.
/// While it is running, new progress events replace `pending` instead of
/// spawning more writers. If macOS stalls one filesystem call, the player UI
/// remains responsive and the pending memory footprint stays bounded to one
/// snapshot.
private actor MacWidgetPlaybackPublisher {
    static let shared = MacWidgetPlaybackPublisher()

    private struct PublicationContext: Sendable {
        let lastCoverSongID: String?
        let lastTimelineSignature: String?
    }

    private struct PublicationResult: Sendable {
        let lastCoverSongID: String?
        let lastTimelineSignature: String?
    }

    private var pending: MacWidgetPlaybackPublishRequest?
    private var workerTask: Task<Void, Never>?
    private var lastCoverSongID: String?
    private var lastTimelineSignature: String?

    func enqueue(_ request: MacWidgetPlaybackPublishRequest) {
        pending = request
        guard workerTask == nil else { return }
        workerTask = Task { [weak self] in
            await self?.drain()
        }
    }

    private func drain() async {
        while let request = pending {
            pending = nil
            let context = PublicationContext(
                lastCoverSongID: lastCoverSongID,
                lastTimelineSignature: lastTimelineSignature
            )
            let result = await Task.detached(priority: .utility) {
                Self.publish(request, context: context)
            }.value
            lastCoverSongID = result.lastCoverSongID
            lastTimelineSignature = result.lastTimelineSignature
        }
        workerTask = nil
    }

    private nonisolated static func publish(
        _ request: MacWidgetPlaybackPublishRequest,
        context: PublicationContext
    ) -> PublicationResult {
        guard WidgetSettings.syncEnabled(),
              WidgetSettings.widgetEnabled(PrimuseConstants.widgetNowPlayingEnabledKey) else {
            PlaybackState.clear()
            WidgetCenter.shared.reloadAllTimelines()
            return PublicationResult(lastCoverSongID: nil, lastTimelineSignature: nil)
        }

        let scope = WidgetSettings.sharedDataScope()
        let recentAlbumsEnabled = scope.includesCover
            && WidgetSettings.widgetEnabled(PrimuseConstants.widgetRecentAlbumsEnabledKey)
        var coverName: String?
        var recentAlbumsChanged = false
        var nextCoverSongID = context.lastCoverSongID

        if !scope.includesCover {
            clearSharedCovers()
            nextCoverSongID = nil
            if WidgetSettings.widgetEnabled(PrimuseConstants.widgetRecentAlbumsEnabledKey),
               !RecentAlbumsStore.load().isEmpty {
                RecentAlbumsStore.clear()
                recentAlbumsChanged = true
            }
        } else if let song = request.currentSong {
            let sharedCoverName = "widget_cover.png"
            let needsRefresh = song.id != context.lastCoverSongID
                || !sharedCoverExists(named: sharedCoverName)

            if needsRefresh {
                if writeCover(song: song, fileName: sharedCoverName) {
                    coverName = sharedCoverName
                    nextCoverSongID = song.id
                } else {
                    removeSharedCover(named: sharedCoverName)
                    nextCoverSongID = nil
                }

                if recentAlbumsEnabled, let albumEntry = makeRecentAlbumEntry(for: song) {
                    if let albumCoverName = albumEntry.coverImageName,
                       !sharedCoverExists(named: albumCoverName) {
                        _ = writeCover(song: song, fileName: albumCoverName, size: 200)
                    }
                    RecentAlbumsStore.record(albumEntry)
                    recentAlbumsChanged = true
                }
            } else {
                coverName = sharedCoverName
            }

            if !recentAlbumsEnabled {
                RecentAlbumsStore.clear()
                recentAlbumsChanged = true
            }
        } else {
            nextCoverSongID = nil
        }

        let state = PlaybackState(
            currentSongID: request.currentSong?.id,
            songTitle: request.currentSong?.title,
            artistName: request.currentSong?.artistName,
            albumTitle: request.currentSong?.albumTitle,
            fileFormat: request.currentSong.map { $0.fileFormat.displayName },
            coverImageName: coverName,
            isPlaying: request.isPlaying,
            currentTime: scope.includesProgress ? request.currentTime : 0,
            duration: scope.includesProgress ? request.duration : 0,
            queueSongIDs: request.queueSongIDs
        )
        state.save()

        let signature = timelineSignature(for: state)
        if recentAlbumsChanged || signature != context.lastTimelineSignature {
            WidgetCenter.shared.reloadAllTimelines()
        }
        return PublicationResult(
            lastCoverSongID: nextCoverSongID,
            lastTimelineSignature: signature
        )
    }

    private nonisolated static func writeCover(
        song: Song,
        fileName: String,
        size: Int = 300
    ) -> Bool {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: PrimuseConstants.appGroupIdentifier
        ) else { return false }

        let store = MetadataAssetStore.shared
        var coverData = store.readCoverData(named: store.expectedCoverFileName(for: song.id))
        if coverData == nil, let ref = song.coverArtFileName, !ref.isEmpty,
           !ref.contains("/"), !ref.contains("://") {
            coverData = store.readCoverData(named: ref)
        }
        guard let coverData, let jpeg = squareJPEG(from: coverData, size: size) else {
            return false
        }

        do {
            try jpeg.write(
                to: containerURL.appendingPathComponent(fileName),
                options: .atomic
            )
            return true
        } catch {
            return false
        }
    }

    /// ImageIO/CoreGraphics are safe for background thumbnail work; using
    /// NSImage drawing here would bring AppKit's main-thread assumptions back
    /// into the detached publisher.
    private nonisolated static func squareJPEG(from data: Data, size: Int) -> Data? {
        autoreleasepool {
            guard size > 0,
                  !ArtworkImageCompatibility.hasRedundantJPEGSampling(data),
                  let source = CGImageSourceCreateWithData(data as CFData, nil) else {
                return nil
            }
            let options = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: max(size * 2, size),
            ] as CFDictionary
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else {
                return nil
            }

            let colorSpace = CGColorSpaceCreateDeviceRGB()
            guard let context = CGContext(
                data: nil,
                width: size,
                height: size,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }

            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: size, height: size))
            context.interpolationQuality = .high
            let scale = max(
                CGFloat(size) / CGFloat(image.width),
                CGFloat(size) / CGFloat(image.height)
            )
            let drawWidth = CGFloat(image.width) * scale
            let drawHeight = CGFloat(image.height) * scale
            context.draw(
                image,
                in: CGRect(
                    x: (CGFloat(size) - drawWidth) / 2,
                    y: (CGFloat(size) - drawHeight) / 2,
                    width: drawWidth,
                    height: drawHeight
                )
            )
            guard let outputImage = context.makeImage() else { return nil }

            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(
                output,
                UTType.jpeg.identifier as CFString,
                1,
                nil
            ) else { return nil }
            let destinationOptions = [
                kCGImageDestinationLossyCompressionQuality: 0.8,
            ] as CFDictionary
            CGImageDestinationAddImage(destination, outputImage, destinationOptions)
            guard CGImageDestinationFinalize(destination) else { return nil }
            return output as Data
        }
    }

    private nonisolated static func sharedCoverExists(named fileName: String) -> Bool {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: PrimuseConstants.appGroupIdentifier
        ) else { return false }
        return FileManager.default.fileExists(
            atPath: containerURL.appendingPathComponent(fileName).path
        )
    }

    private nonisolated static func removeSharedCover(named fileName: String) {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: PrimuseConstants.appGroupIdentifier
        ) else { return }
        try? FileManager.default.removeItem(at: containerURL.appendingPathComponent(fileName))
    }

    private nonisolated static func clearSharedCovers() {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: PrimuseConstants.appGroupIdentifier
        ) else { return }
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: containerURL.appendingPathComponent("widget_cover.png"))
        guard let entries = try? fileManager.contentsOfDirectory(
            at: containerURL,
            includingPropertiesForKeys: nil
        ) else { return }
        for url in entries where url.lastPathComponent.hasPrefix("widget_album_") {
            try? fileManager.removeItem(at: url)
        }
    }

    private nonisolated static func makeRecentAlbumEntry(for song: Song) -> RecentAlbumEntry? {
        guard let title = song.albumTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else { return nil }
        let artist = song.artistName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let baseKey = song.albumID ?? "\(song.sourceID)|\(title.lowercased())|\(artist.lowercased())"
        let digest = SHA256.hash(data: Data(baseKey.utf8))
        let key = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        return RecentAlbumEntry(
            id: key,
            title: title,
            artistName: artist,
            coverImageName: "widget_album_\(key).jpg"
        )
    }

    private nonisolated static func timelineSignature(for state: PlaybackState) -> String {
        [
            state.currentSongID ?? "",
            state.songTitle ?? "",
            state.artistName ?? "",
            state.albumTitle ?? "",
            state.coverImageName ?? "",
            state.isPlaying ? "1" : "0",
            String(state.currentTime.rounded().finiteInt()),
            String(state.duration.rounded().finiteInt()),
        ].joined(separator: "|")
    }
}
#endif

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
        didSet {
            currentTimeAnchor = Date()
            handoffCurrentTime = currentTime
        }
    }
    private(set) var duration: TimeInterval = 0
    private(set) var isLoading = false
    private(set) var lastPlaybackError: String?
    /// `currentSong` is published before remote resolution finishes, so it
    /// cannot tell resume whether a local decoder has scheduled any audio.
    @ObservationIgnored private var hasPreparedLocalPlayback = false
    private(set) var musicVideoPlayer: AVPlayer?
    private(set) var isMusicVideoModeEnabled = false
    private(set) var isMusicVideoPlaybackActive = false
    private(set) var musicVideoAudioFallbackToken = UUID()

    /// Timeline-driven lyric views read this value while rendering, but they
    /// already own their own clocks. Publishing an additional Observation
    /// mutation for every progress sample only creates a second invalidation
    /// wave, so keep the interpolation anchor outside the observable graph.
    @ObservationIgnored private(set) var currentTimeAnchor: Date = Date()

    /// `NSUserActivity` asks for a point-in-time progress snapshot. Reading the
    /// observable `currentTime` from its update closure made the entire now
    /// playing hierarchy (including an open Menu) refresh every 0.5 seconds.
    /// Mirror the value into ignored storage so Handoff can sample it without
    /// becoming a high-frequency UI dependency.
    @ObservationIgnored private var handoffCurrentTime: TimeInterval = 0

    func handoffPlaybackTimeSnapshot() -> TimeInterval {
        handoffCurrentTime
    }

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

    /// Stored backing for the queue. Each entry pairs a Song with a
    /// stable UUID — see `QueueEntry`. Mutate via `setQueue`,
    /// `clearQueue`, `moveQueueItems`, or `syncSongMetadata`; do NOT
    /// hand-edit from outside.
    private(set) var queueEntries: [QueueEntry] = []
    /// Backward-compatible read-only view over the queue's songs.
    /// Internal callers and observers keep using `player.queue` —
    /// the @Observable macro tracks reads through `queueEntries`,
    /// so SwiftUI re-renders correctly when entries change.
    var queue: [Song] { queueEntries.map(\.song) }
    var currentIndex: Int = 0
    var shuffleEnabled = false {
        didSet {
            // mirror task 同步 Apple Music shuffle 时跳过 — 不要再写回 AM
            // 触发 polling 抖动。本地播放时正常重建 shuffle order。
            if isMirroringFromAppleMusic { return }
            if isAppleMusicMode && !isPrimuseManagingAppleMusicQueue {
                AppServices.shared.appleMusic.setAppleMusicShuffle(shuffleEnabled)
                return
            }
            invalidateQueueTransitions()
            rebuildShuffleOrder()
        }
    }
    var repeatMode: RepeatMode = .off {
        didSet {
            if isMirroringFromAppleMusic { return }
            if isAppleMusicMode && !isPrimuseManagingAppleMusicQueue {
                AppServices.shared.appleMusic.setAppleMusicRepeat(repeatMode)
                return
            }
            invalidateQueueTransitions()
        }
    }

    /// 当前 currentSong 是不是 Apple Music 来源 ── 一切跨 player 路由 (next /
    /// previous / seek / togglePlayPause / 进度 / queue / repeat / shuffle) 都
    /// 通过这个 flag 走系统侧 ApplicationMusicPlayer, 让 NowPlayingView 一份
    /// 实现两套播放器通吃。
    var isAppleMusicMode: Bool {
        currentSong?.sourceID == AppleMusicLibraryService.systemSourceID
    }

    /// mirror task 写自己字段时设为 true, 让 didSet 跳过"再写回 Apple Music"
    /// 的副作用, 避免 mirror → setRepeat/setShuffle → polling → mirror 的回环。
    private var isMirroringFromAppleMusic = false

    /// `true` when playback came from Primuse's canonical queue. MusicKit only
    /// receives the current DRM track; Primuse retains ordering, repeat and
    /// shuffle so every Apple Music boundary advances the same visible queue.
    private var isPrimuseManagingAppleMusicQueue = false

    // MARK: - DLNA Casting (推到外部 Renderer)

    /// 当前正在投屏的 RemoteRenderer。nil = 本机播放。
    /// 跟 isAppleMusicMode 一样作为路由开关: togglePlayPause / next / previous /
    /// seek 检测到 isCastingMode 后走 RemoteRendererController 而不是 audioEngine。
    private(set) var castingRenderer: RemoteRenderer?

    /// 跟当前 castingRenderer 对应的 SOAP controller。生命周期跟 castingRenderer 绑定。
    private var castingController: RemoteRendererController?

    /// 1Hz 轮询 GetPositionInfo + GetTransportInfo 同步进度 / 播放状态。
    private var castingPositionTask: Task<Void, Never>?
    /// Replacement Apple Music requests await the same renderer Stop instead
    /// of observing a temporarily detached controller and starting early.
    private var appleMusicCastingHandoffTask: Task<Bool, Never>?
    private var appleMusicCastingHandoffID = UUID()
    private var appleMusicCastingHandoffController: RemoteRendererController?
    private var appleMusicCastingHandoffRenderer: RemoteRenderer?

    var isCastingMode: Bool { castingRenderer != nil }
    private var appleMusicPlaybackTask: Task<Void, Never>?
    private var appleMusicTimeoutTask: Task<Void, Never>?
    private var activeAppleMusicRequestID: UUID?
    private var appleMusicMirrorTask: Task<Void, Never>?
    /// Invalidates suspended observation tasks when playback changes owner.
    /// Cancellation alone is insufficient because a checked continuation can
    /// still resume once after `stopAppleMusic()` mutates the observed state.
    private var appleMusicMirrorGeneration: UInt64 = 0
    private var rescuedAppleMusicLyricsAliases: Set<String> = []
    private var musicVideoTimeObserver: Any?
    private var musicVideoEndObserver: NSObjectProtocol?
    private var musicVideoStatusObservation: NSKeyValueObservation?
    private var musicVideoFailedObserver: NSObjectProtocol?
    /// AVAssetResourceLoader 对 delegate 是弱引用, 流式播放期间必须强持有。
    private var musicVideoStreamingLoader: MusicVideoStreamingLoader?
    #if os(iOS)
    private var isCarPlaySceneActive = false
    private var carPlayConnectObserver: NSObjectProtocol?
    private var carPlayDisconnectObserver: NSObjectProtocol?
    private var carAudioRouteObserver: NSObjectProtocol?
    #endif

    var canPlayMusicVideo: Bool {
        guard let song = currentSong,
              song.mvPath?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return false
        }
        return !isAppleMusicMode && !isCastingMode && !shouldForceAudioOnly
    }

    private var shouldForceAudioOnly: Bool {
        #if os(iOS)
        return isCarPlaySceneActive || Self.isCarAudioRouteActive()
        #else
        return false
        #endif
    }

    #if os(iOS)
    private static func isCarAudioRouteActive() -> Bool {
        AVAudioSession.sharedInstance().currentRoute.outputs.contains { output in
            output.portType == .carAudio
        }
    }
    #endif

    // MARK: - Shuffle Order
    private var shuffledIndices: [Int] = []
    private var shufflePosition: Int = 0
    /// Pre-computed next round used by repeat-all wrap-around. Generated on
    /// first demand from queue preview or prefetch so `nextSongInQueue` and
    /// `advanceToNextIndex` adopt exactly the visible order. Cleared on any
    /// structural change to `queue` / shuffle state.
    @ObservationIgnored private var pendingNextShuffleIndices: [Int]?
    /// Invalidates prepared gapless transitions when queue order changes.
    private var queueGeneration = 0

    // MARK: - Decoder Tracking (for seek)
    /// Tracks which decoder pipeline produced the currently-playing audio
    /// stream so seek/crossfade/recovery can reproduce the exact same path.
    /// `cloudStream` means SFBAudio decoding from a `CloudPlaybackSource`
    /// `InputSource` (Range-fetch + sparse cache). Seeking that path
    /// requires building a NEW `InputSource` — feeding the
    /// `primuse-stream://` URL to SFB's URL-based opener fails because
    /// the scheme isn't registered with the file system.
    fileprivate enum DecoderKind: Sendable, Equatable { case native, ffmpeg, streaming, httpStream, cloudStream, assetReader }
    private struct CommittedCrossfade {
        let attemptID: UUID
        let playID: UUID
        let song: Song
        let url: URL
        let decoderKind: DecoderKind
    }
    private var activeDecoderKind: DecoderKind = .native
    private var activeDSDPlaybackMode: DSDPlaybackMode = .pcm

    // MARK: - Sleep Timer
    private(set) var sleepTimerEndDate: Date?
    private var sleepTimerTask: Task<Void, Never>?
    /// "曲终停止" 模式: 持有当前歌曲的 id, 一旦切到下一首 (或 currentSong
    /// 变 nil) 立即 pause。比固定分钟数更智能 ── 不会在曲子中间硬切。
    private(set) var sleepStopAfterSongID: String?
    var isSleepTimerActive: Bool { sleepTimerEndDate != nil || sleepStopAfterSongID != nil }

    private var displayLink: Timer?
    /// Completion callbacks from AVAudioPlayerNode are occasionally lost after
    /// route changes. Keep a near-end progress watchdog so a drained first
    /// track cannot leave a non-empty queue stuck forever.
    private var lastEngineProgressSample: TimeInterval?
    private var nearEndStallSampleCount = 0
    private static let trackEndStallSampleThreshold = 4
    private let nativeDecoder = NativeAudioDecoder()
    private let ffmpegDecoder = FFmpegAudioDecoder()

    /// 一次性 hint: 搜索页点歌词命中结果时填入, NowPlayingView 加载好歌词后
    /// 用这串文本 fuzzy match 找到对应 LyricLine.timestamp 并 seek。命中后
    /// NowPlayingView 调 `clearPendingLyricsJump()` 清空。
    /// userInfo: (songID, snippet)。songID 防止匹配到错首歌 (用户快速切歌)。
    private(set) var pendingLyricsJump: (songID: String, snippet: String)?

    func requestLyricsJump(songID: String, snippet: String) {
        pendingLyricsJump = (songID, snippet)
    }

    func clearPendingLyricsJump() {
        pendingLyricsJump = nil
    }
    private let assetReaderDecoder = AssetReaderDecoder()
    private let streamingDecoder = StreamingDownloadDecoder()
    private var decodingTask: Task<Void, Never>?
    private var prefetchTask: Task<Void, Never>?
    private var gaplessPreparationTask: Task<Void, Never>?
    private var gaplessFollowupTask: Task<Void, Never>?
    private var crossfadeStartupTask: Task<Void, Never>?
    private var crossfadeDecodingTask: Task<Void, Never>?
    private var crossfadeAttemptID: UUID?
    private var committedCrossfade: CommittedCrossfade?
    /// swapPlayerNodes() 之后, crossfade 解码任务正在喂的那个物理节点已经
    /// 从 crossfade 节点变成 primary 节点。该任务必须改用 scheduleBuffer
    /// (primary) 继续投递, 否则 buffer 会落到换出后被 stop/reset/静音的旧
    /// 节点上, 导致 swap 后剩余音频丢失(歌中途静音)。completeCrossfade 置
    /// true, startCrossfade 每次重置为 false。两者都在 MainActor, 不会
    /// 与解码循环的单条 schedule 语句交错。
    private var crossfadeSwapDone = false
    private var crossfadeTimer: Timer?
    private var crossfadeTimerAttemptID: UUID?
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

    /// 最近一段时间 gapless boundary 触发的时间戳, 用于侦测 partial-cache
    /// 引起的死循环 (boundary 反复在几秒内连续触发, 队列里 1-2 首坏歌
    /// 互相切来切去)。窗口外的记录会被丢掉。
    private var recentBoundaryTimes: [Date] = []
    private static let boundaryStormWindow: TimeInterval = 10
    private static let boundaryStormThreshold = 4

    /// A queue whose source is unavailable can otherwise recurse through every
    /// item in a few milliseconds. Keep ordinary corrupt-file skipping useful,
    /// but bound one continuous failure chain so UI/log/CPU remain responsive.
    private var isFailureAdvanceChainActive = false
    private var consecutiveFailureAdvanceCount = 0
    private static let maxConsecutiveFailureAdvances = 8

    /// Seconds of buffered audio we let drain before forcibly advancing
    /// after a mid-stream decode error. Without this cap, the ~100 buffers
    /// already scheduled to the playerNode play out for ~20s before
    /// `autoAdvanceAfterFailure` fires — looks like the player is frozen
    /// (most painfully on CarPlay where the user has no other UI to fall
    /// back to). 3s is enough that the user hears "this song stuttered"
    /// rather than a sudden cut, but short enough to feel responsive.
    private static let midStreamErrorGrace: TimeInterval = 3
    /// Target decoded PCM duration scheduled-but-not-yet-consumed on the player
    /// node. Counting buffers alone is unsafe: NativeAudioDecoder usually emits
    /// ~0.2s chunks, while FFmpeg DTS frames can be only ~10ms. Three seconds of
    /// duration-based lookahead keeps realtime playback resilient when metadata
    /// scraping or artwork decoding briefly loads the cooperative executor.
    private static let decodedAudioLookahead: TimeInterval = 3
    /// Hard cap for pathological tiny/invalid buffers. Duration remains the
    /// primary bound, so normal PCM residency stays around the lookahead window.
    private static let maxInFlightDecodedBufferCount = 384

    private static func decodedBufferDuration(_ buffer: AVAudioPCMBuffer) -> TimeInterval {
        let sampleRate = buffer.format.sampleRate
        guard sampleRate.isFinite, sampleRate > 0, buffer.frameLength > 0 else {
            // Preserve the old 16-buffer behavior when a decoder reports an
            // unusable format rather than letting hundreds of buffers queue.
            return decodedAudioLookahead / 16
        }
        return Double(buffer.frameLength) / sampleRate
    }
    private static let firstBufferTimeoutSeconds = 35
    private static let remoteFallbackFirstBufferTimeoutSeconds = 60
    private static let dlnaSourceID = "dlna"

    let playbackSettings: PlaybackSettingsStore

    init(sourceManager: SourceManager? = nil, library: MusicLibrary? = nil, playbackSettings: PlaybackSettingsStore = PlaybackSettingsStore()) {
        self.sourceManager = sourceManager
        self.library = library
        self.playbackSettings = playbackSettings
        audioEngine = AudioEngine()
        equalizerService = EqualizerService(audioEngine: audioEngine)
        audioEffectsService = AudioEffectsService(audioEngine: audioEngine, settingsStore: playbackSettings)
        applySpatialAudioSettings()
        applyPlaybackRate()
        observeSpatialAudioSettings()
        observePlaybackRate()
        observeOutputPipelineSettings()
        #if os(iOS)
        observeCarAudioRouteState()
        #endif

        // 服务端曲库源(Subsonic/Navidrome)回报回调 —— 把 ScrobbleService 的播放
        // 事件按源路由到对应 connector 的 /rest/scrobble。非服务端源 no-op。
        ScrobbleService.shared.serverScrobbleHandler = { [weak self] song, submission in
            guard let manager = self?.sourceManager else { return }
            Task { await manager.reportServerScrobble(for: song, submission: submission) }
        }

        // Defer heavy system registrations to avoid blocking first frame
        Task { @MainActor [weak self] in
            AudioSessionManager.shared.prepareForPlayback()
            self?.setupRemoteCommands()
            self?.setupAudioSessionCallbacks()
        }

        // Apple Music 路径 (SearchView 直接点 catalog row) 不走我们的 play(song:),
        // 用 notification 解耦让 player 主动让出 audio session + 清 currentSong,
        // 这样 mini player 才能切到 AppleMusicAccessory。
        NotificationCenter.default.addObserver(
            forName: .primuseAppleMusicWillPlay,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let requestID = notification.object as? UUID
            Task { @MainActor [weak self, requestID] in
                guard let requestID else { return }
                self?.yieldToAppleMusic(requestID: requestID)
            }
        }
    }

    /// 让出 audio session 给 Apple Music 系统播放器 — 停掉所有内部播放状态。
    ///
    /// 关键: 必须先 bump playID 让正在 in-flight 的 SFB `dataPlayedBack`
    /// completion handler 看到 guard 失败直接 return。否则我们调
    /// `stopPlayback()` 时, SFB lastBuffer 被认为 "完整播放完" → 触发
    /// `handleTrackEnd()` → 自动跳到队列下一首本地歌 → mini player 又切
    /// 回本地, 用户体感是"Apple Music 一闪而过又变回本地播放"。
    ///
    /// **不再清空 currentSong** ── mirror task 会从 appleMusic.nowPlayingSong
    /// 翻译过来设上, 让 NowPlayingView 复用同一份实现; 仅本地引擎和 time
    /// updater 停掉。
    private func yieldToAppleMusic(requestID: UUID) {
        let appleMusic = AppServices.shared.appleMusic
        guard appleMusic.isPlaybackRequestActive(requestID) else { return }
        appleMusicPlaybackTask?.cancel()
        appleMusicPlaybackTask = nil
        appleMusicTimeoutTask?.cancel()
        appleMusicTimeoutTask = nil
        activeAppleMusicRequestID = requestID
        // Use the Apple Music request itself as playID so every async callback,
        // mirror update and timeout has one shared generation identity.
        playID = requestID
        decodingTask?.cancel(); decodingTask = nil
        cancelGaplessTasks()
        cancelCrossfadeAttempt()
        audioEngine.stopPlayback()
        hasPreparedLocalPlayback = false
        stopTimeUpdater()
        currentTime = 0
        duration = 0
        isLoading = true
        isPlaying = false
        beginPlaybackErrorScope()
        isPrimuseManagingAppleMusicQueue = false
        startAppleMusicMirror(requestID: requestID)
        plog("⏸ yielded audio session to Apple Music (playID bumped)")
    }

    func applySpatialAudioSettings() {
        let settings = playbackSettings.snapshot()
        let effectsEnabled = settings.outputMode == .effects
        audioEngine.configureSpatialAudio(
            enabled: effectsEnabled && settings.spatialAudioEnabled,
            headTrackingEnabled: effectsEnabled && settings.spatialHeadTrackingEnabled
        )
    }

    /// 同步当前 playbackRate 到 engine. 设置变化或新歌开播都会调它。
    func applyPlaybackRate() {
        audioEngine.applyPlaybackRate(
            playbackSettings.outputMode == .effects ? playbackSettings.playbackRate : 1
        )
    }

    /// 如果用户启用了「输出采样率匹配」, 把 AVAudioSession 硬件 SR hint 切到
    /// 当前歌的采样率, 避免 CoreAudio 自动重采样。仅 iOS 真机生效。
    func applyOutputSampleRateMatching(for song: Song) {
        guard (playbackSettings.matchOutputSampleRate || playbackSettings.outputMode == .highFidelity),
              let sr = song.sampleRate, sr > 0 else { return }
        _ = audioEngine.prepareHardwareSampleRate(Double(sr))
    }

    private func shouldApplyReplayGain(_ settings: PlaybackSettings) -> Bool {
        settings.outputMode == .effects && settings.replayGainEnabled
    }

    private func shouldUseCrossfade(_ settings: PlaybackSettings) -> Bool {
        settings.outputMode == .effects && settings.crossfadeEnabled
    }

    /// Negotiates the render graph before decoder creation. DoP is only used
    /// when a DSP-free graph is selected and the output reports the exact DoP
    /// carrier sample rate. Unsupported routes safely fall back to PCM.
    private func configureOutputPipeline(for song: Song, url: URL) async throws -> DSDPlaybackMode {
        let settings = playbackSettings.snapshot()
        let isLocalDSD = url.isFileURL && nativeDecoder.isDSD(url)

        if isLocalDSD,
           settings.outputMode == .highFidelity,
           settings.dsdPlaybackMode != .pcm,
           let dopFormat = try? nativeDecoder.dsdOutputFormat(for: url, mode: .dop) {
            _ = audioEngine.prepareHardwareSampleRate(dopFormat.sampleRate)
            _ = AudioSessionManager.shared.activatePlaybackSession()
            if audioEngine.hardwareSupportsDirectFormat(dopFormat) {
                try audioEngine.configure(outputMode: .highFidelity, directSourceFormat: dopFormat)
                plog("🎧 DSD output: DoP \(dopFormat.sampleRate) Hz direct")
                return .dop
            }
            plog("ℹ️ DoP carrier \(dopFormat.sampleRate) Hz unavailable; falling back to PCM")
        }

        var directPCMFormat: AVAudioFormat?
        if isLocalDSD,
           let pcmFormat = try? nativeDecoder.dsdOutputFormat(for: url, mode: .pcm) {
            _ = audioEngine.prepareHardwareSampleRate(pcmFormat.sampleRate)
            if settings.outputMode == .highFidelity {
                directPCMFormat = pcmFormat
            }
        } else {
            var sourceSampleRate = song.sampleRate.map(Double.init)
            if sourceSampleRate == nil, url.isFileURL {
                let decoder: any PrimuseAudioDecoder = await usesFFmpegDecoder(
                    for: song,
                    url: url
                ) ? ffmpegDecoder : nativeDecoder
                sourceSampleRate = try? await decoder.fileInfo(for: url).sampleRate
            }
            if (settings.matchOutputSampleRate || settings.outputMode == .highFidelity),
               let sourceSampleRate,
               sourceSampleRate > 0 {
                _ = audioEngine.prepareHardwareSampleRate(sourceSampleRate)
            }
            if settings.outputMode == .highFidelity,
               let sourceSampleRate,
               sourceSampleRate > 0 {
                directPCMFormat = audioEngine.directPCMFormat(
                    sampleRate: sourceSampleRate
                )
            }
        }

        _ = AudioSessionManager.shared.activatePlaybackSession()
        try audioEngine.configure(
            outputMode: settings.outputMode,
            directSourceFormat: directPCMFormat
        )
        return .pcm
    }

    /// A failed DoP decoder must never feed ordinary PCM into a DoP carrier
    /// graph. Rebuild the normal direct path before trying FFmpeg/AVFoundation.
    private func preparePCMOutputAfterDoPFailure(
        song: Song,
        url: URL,
        wasUsingDoP: Bool
    ) -> AVAudioFormat? {
        guard wasUsingDoP else { return audioEngine.outputFormat }
        audioEngine.stopPlayback()
        let decodedPCMFormat = try? nativeDecoder.dsdOutputFormat(
            for: url,
            mode: .pcm
        )
        if let decodedPCMFormat {
            _ = audioEngine.prepareHardwareSampleRate(decodedPCMFormat.sampleRate)
        } else {
            applyOutputSampleRateMatching(for: song)
        }
        do {
            let directFormat = playbackSettings.outputMode == .highFidelity
                ? decodedPCMFormat
                : nil
            try audioEngine.configure(
                outputMode: playbackSettings.outputMode,
                directSourceFormat: directFormat
            )
            try audioEngine.start()
            return audioEngine.outputFormat
        } catch {
            plog("⚠️ Failed to rebuild PCM output after DoP error: \(error.localizedDescription)")
            return nil
        }
    }

    private func observeSpatialAudioSettings() {
        withObservationTracking {
            _ = playbackSettings.spatialAudioEnabled
            _ = playbackSettings.spatialHeadTrackingEnabled
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.applySpatialAudioSettings()
                self.observeSpatialAudioSettings()
            }
        }
    }

    /// 单独跟踪 playbackRate, 别和 spatial observer 合并 — 不然改速度时会
    /// 顺带触发 spatial node 的 sourceMode / renderingAlgorithm 重设, 在
    /// engine 运行中可能导致音频 glitch / player 卡顿。
    private func observePlaybackRate() {
        withObservationTracking {
            _ = playbackSettings.playbackRate
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.applyPlaybackRate()
                self.observePlaybackRate()
            }
        }
    }

    /// Output-mode and DSD-policy changes alter the graph itself. Rebuild at
    /// the current playback position so the selection takes effect immediately
    /// without waiting for the next track.
    private func observeOutputPipelineSettings() {
        withObservationTracking {
            _ = playbackSettings.outputMode
            _ = playbackSettings.dsdPlaybackMode
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.currentSong != nil, !self.isLoading, !self.isMusicVideoPlaybackActive {
                    self.seek(to: self.currentTime, startPlaying: self.isPlaying)
                } else {
                    self.applySpatialAudioSettings()
                    self.applyPlaybackRate()
                }
                self.observeOutputPipelineSettings()
            }
        }
    }

    private func setupAudioSessionCallbacks() {
        let manager = AudioSessionManager.shared

        manager.onInterruptionBegan = { [weak self] in
            guard let self, self.currentSong != nil else { return }
            if self.isAppleMusicMode {
                AppServices.shared.appleMusic.markPlaybackInterrupted()
            }
            let wasPlaying = self.isPlaying
            // Once a fade has committed, currentSong already points at the
            // incoming track while the engine's primary node still belongs to
            // the outgoing one. Finish the node swap before reading progress,
            // otherwise the old track's tail becomes the new track's recovery
            // position after the interruption.
            self.cancelCrossfadeAttempt(finishingCommittedTransition: true)
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
            self.cancelCrossfadeAttempt(finishingCommittedTransition: true)
            self.syncPlaybackProgressFromEngine()
            self.pendingRecoveryTime = self.currentTime
            self.needsPlaybackRecovery = self.needsPlaybackRecovery || shouldAutoResume

            if self.isMusicVideoPlaybackActive { return }

            guard shouldAutoResume else { return }
            // Engine was stopped due to config change — restart it if possible, and
            // rebuild the player pipeline on the next resume/play if buffers were lost.
            self.audioEngine.restartIfNeeded()
        }
    }

    #if os(iOS)
    private func observeCarAudioRouteState() {
        guard carPlayConnectObserver == nil else { return }
        let center = NotificationCenter.default

        carPlayConnectObserver = center.addObserver(
            forName: .primuseCarPlaySceneDidConnect,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isCarPlaySceneActive = true
                self.forceAudioOnlyIfNeeded()
            }
        }

        carPlayDisconnectObserver = center.addObserver(
            forName: .primuseCarPlaySceneDidDisconnect,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.isCarPlaySceneActive = false
            }
        }

        carAudioRouteObserver = center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.forceAudioOnlyIfNeeded()
            }
        }
    }

    private func forceAudioOnlyIfNeeded() {
        guard shouldForceAudioOnly, isMusicVideoPlaybackActive else { return }
        Task { await replayCurrentSongAsAudio(restoreMusicVideoModeAfterPlay: true) }
    }
    #endif

    private func clearPendingPlaybackRecovery() {
        shouldResumeAfterInterruption = false
        needsPlaybackRecovery = false
        pendingRecoveryTime = 0
    }

    private func syncPlaybackProgressFromEngine() {
        if isMusicVideoPlaybackActive {
            let seconds = musicVideoPlayer?.currentTime().seconds ?? currentTime
            guard seconds.isFinite else { return }
            currentTime = max(0, seconds)
            return
        }
        guard let engineTime = audioEngine.currentTime, engineTime.isFinite else { return }
        currentTime = max(0, engineTime)
    }

    func toggleMusicVideoMode() {
        Task { await setMusicVideoModeEnabled(!isMusicVideoModeEnabled) }
    }

    func setMusicVideoModeEnabled(_ enabled: Bool) async {
        guard enabled != isMusicVideoModeEnabled else { return }
        guard let song = currentSong else {
            isMusicVideoModeEnabled = enabled
            return
        }
        // 独立 MV 不受模式开关影响(始终走视频管线), 只记开关不重启播放。
        if song.isStandaloneMusicVideo {
            isMusicVideoModeEnabled = enabled
            return
        }
        guard enabled == false || canPlayMusicVideo else {
            // UI 只在 canPlayMusicVideo 时展示开关, 走到这里说明状态刚变
            // (歌切走 / 进投屏), 静默忽略即可, 弹连接错误反而误导。
            plog("🎞️ MV mode enable ignored: current song has no playable MV")
            return
        }

        let resumeTime = currentTime
        let shouldPlay = isPlaying || isLoading
        isMusicVideoModeEnabled = enabled

        await play(song: song)
        if resumeTime > 0 {
            await waitForPlaybackPipelineSettled()
            seek(to: resumeTime, startPlaying: shouldPlay)
        }
        if !shouldPlay {
            pause()
        }
    }

    private func replayCurrentSongAsAudio(restoreMusicVideoModeAfterPlay: Bool) async {
        guard let song = currentSong else { return }
        let resumeTime = currentTime
        let shouldPlay = isPlaying || isLoading
        let previousMode = isMusicVideoModeEnabled

        isMusicVideoModeEnabled = false
        await play(song: song)
        if restoreMusicVideoModeAfterPlay {
            isMusicVideoModeEnabled = previousMode
        }
        if resumeTime > 0 {
            await waitForPlaybackPipelineSettled()
            seek(to: resumeTime, startPlaying: shouldPlay)
        }
        if !shouldPlay {
            pause()
        }
    }

    /// 模式切换后恢复进度前, 等播放管线真正就绪(isLoading 清除)再 seek,
    /// 而不是赌一个固定延时 —— 慢源加载超时前 seek 会打在半初始化的管线上。
    private func waitForPlaybackPipelineSettled(maxWait: Duration = .seconds(3)) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: maxWait)
        while isLoading, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    private enum MusicVideoStartResult {
        case started
        case skipped
        case needsAudioFallback
    }

    private func startMusicVideoPlaybackIfAvailable(for song: Song, playID id: UUID) async -> MusicVideoStartResult {
        // 独立 MV(媒体本体是视频)不受全局 MV 模式 / 车机强制音频约束 ——
        // 它没有独立音频可回落; AVPlayer 播它的音轨在车机路由下同样出声,
        // 强行走音频管线反而要 SFB 硬解视频容器(不可靠)。
        guard !isAppleMusicMode,
              !isCastingMode,
              let sourceManager,
              let mvPath = song.mvPath?.trimmingCharacters(in: .whitespacesAndNewlines),
              mvPath.isEmpty == false,
              song.isStandaloneMusicVideo || (isMusicVideoModeEnabled && !shouldForceAudioOnly) else {
            return .skipped
        }

        // 格式预检基于 mvPath 扩展名, 在网络 resolve 之前拦截明确不可播的
        // 容器(mkv/avi 等), 省一次连接开销。
        if let format = VideoFormat.from(fileExtension: (mvPath as NSString).pathExtension),
           format.isNativelyPlayable == false {
            plog("🎞️ MV unsupported format \(format.rawValue) for '\(song.title)'")
            return .needsAudioFallback
        }

        do {
            guard let resolved = try await sourceManager.resolveVideoAsset(for: song) else { return .needsAudioFallback }
            guard playID == id else { return .started }

            _ = AudioSessionManager.shared.activatePlaybackSession()
            stopMusicVideoPlayback(clearPlayer: true)

            let player: AVPlayer
            switch resolved {
            case .url(let url):
                if let format = VideoFormat.from(fileExtension: url.pathExtension),
                   format.isNativelyPlayable == false {
                    plog("🎞️ MV unsupported format \(format.rawValue) for '\(song.title)'")
                    return .needsAudioFallback
                }
                plog("🎞️ MV playback via URL for '\(song.title)' → \(redactedURL(url))")
                player = AVPlayer(url: url)
            case .streaming(let asset, let loader):
                plog("🎞️ MV playback via streaming loader for '\(song.title)'")
                musicVideoStreamingLoader = loader
                player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
            }
            player.automaticallyWaitsToMinimizeStalling = true
            musicVideoPlayer = player
            isMusicVideoPlaybackActive = true
            isAtTrackEnd = false
            currentTime = 0
            duration = song.duration.sanitizedDuration
            isLoading = false
            isPlaying = true
            activeDecoderKind = .native
            configureMusicVideoObservers(for: player, playID: id)

            player.play()
            library?.recordPlayback(of: song.id)
            ScrobbleService.shared.handlePlaybackStarted(song: song)
            PlayHistoryStore.shared.beginSession(song: song)
            updateNowPlayingInfo()
            updateNowPlayingArtworkIfNeeded()
            updatePlaybackState()
            return .started
        } catch {
            guard playID == id else { return .started }
            plog("🎞️ MV resolve failed for '\(song.title)': \(error.localizedDescription)")
            if isMissingMusicVideoFileError(error) {
                clearStaleMusicVideoReference(for: song)
            }
            return .needsAudioFallback
        }
    }

    private func markMusicVideoAudioFallbackIfNeeded(playID id: UUID) {
        guard playID == id,
              isPlaying,
              !isLoading,
              isMusicVideoModeEnabled,
              !isMusicVideoPlaybackActive,
              currentSong?.mvPath?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return
        }
        musicVideoAudioFallbackToken = UUID()
    }

    private func configureMusicVideoObservers(for player: AVPlayer, playID id: UUID) {
        removeMusicVideoObservers()
        let interval = CMTime(seconds: Self.timeUpdateInterval, preferredTimescale: 600)
        musicVideoTimeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self, weak player] time in
            Task { @MainActor [weak self, weak player] in
                guard let self, let player, self.playID == id, self.musicVideoPlayer === player else { return }
                if time.seconds.isFinite {
                    self.currentTime = time.seconds.sanitizedDuration
                    ScrobbleService.shared.handleProgressTick(playedDelta: Self.timeUpdateInterval)
                    PlayHistoryStore.shared.tick(elapsed: self.currentTime)
                }
                if let item = player.currentItem {
                    let itemDuration = item.duration.seconds
                    if itemDuration.isFinite, itemDuration > 0 {
                        self.applyResolvedMusicVideoDuration(itemDuration, playID: id)
                    }
                }
            }
        }

        // status KVO —— 失败检测不能靠 time observer: 启动即失败(坏容器 /
        // 直链失效)时播放时间从不前进, tick 永远不来, UI 会停在假播放态。
        if let item = player.currentItem {
            let box = MusicVideoItemBox(item)
            musicVideoStatusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] observed, _ in
                guard observed.status == .failed else { return }
                let error = observed.error
                Task { @MainActor [weak self] in
                    guard let self, self.playID == id else { return }
                    await self.handleMusicVideoPlaybackFailure(playID: id, error: error, item: box.item)
                }
            }

            musicVideoFailedObserver = NotificationCenter.default.addObserver(
                forName: AVPlayerItem.failedToPlayToEndTimeNotification,
                object: item,
                queue: .main
            ) { [weak self] note in
                let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
                Task { @MainActor [weak self] in
                    guard let self, self.playID == id else { return }
                    await self.handleMusicVideoPlaybackFailure(playID: id, error: error, item: box.item)
                }
            }
        }

        musicVideoEndObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: player.currentItem,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.playID == id else { return }
                self.currentTime = self.duration
                await self.handleTrackEnd()
            }
        }
    }

    private final class MusicVideoItemBox: @unchecked Sendable {
        let item: AVPlayerItem
        init(_ item: AVPlayerItem) { self.item = item }
    }

    private func handleMusicVideoPlaybackFailure(playID id: UUID, error: Error?, item: AVPlayerItem?) async {
        guard playID == id, isMusicVideoPlaybackActive else { return }
        if let song = currentSong {
            plog("🎞️ MV playback failed for '\(song.title)': \(error?.localizedDescription ?? "-")")
            if isMissingMusicVideoPlaybackError(error, item: item) {
                clearStaleMusicVideoReference(for: song)
            }
        }
        showPlaybackError(String(localized: "playback_error_decode"))
        // 独立 MV 没有独立音频可回落, 单个文件坏也不该连坐关掉全局
        // MV 模式 —— 停掉后跳下一首。
        if currentSong?.isStandaloneMusicVideo == true {
            stopMusicVideoPlayback(clearPlayer: true)
            await autoAdvanceAfterFailure()
            return
        }
        isMusicVideoModeEnabled = false
        await replayCurrentSongAsAudio(restoreMusicVideoModeAfterPlay: false)
    }

    private func isMissingMusicVideoFileError(_ error: Error) -> Bool {
        if case SourceError.fileNotFound = error { return true }
        if case SourceError.pathNotFound = error { return true }
        if case CloudDriveError.fileNotFound = error { return true }
        if case CloudDriveError.apiError(let code, _) = error, code == 404 || code == 410 { return true }

        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain, ns.code == Int(ENOENT) {
            return true
        }
        if ns.domain == NSCocoaErrorDomain, ns.code == NSFileNoSuchFileError {
            return true
        }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error {
            return isMissingMusicVideoFileError(underlying)
        }

        return false
    }

    private func isMissingMusicVideoPlaybackError(_ error: Error?, item: AVPlayerItem?) -> Bool {
        if let error, isMissingMusicVideoFileError(error) { return true }
        return item?.errorLog()?.events.contains { event in
            event.errorStatusCode == 404 || event.errorStatusCode == 410
        } == true
    }

    private func clearStaleMusicVideoReference(for song: Song) {
        guard song.mvPath != nil else { return }
        // 独立 MV 的 mvPath 就是文件本身 —— 404 意味着整首歌已不存在,
        // 清 mvPath 只会把它变成解不开的"音频", 留给下次扫描整体移除。
        guard song.isStandaloneMusicVideo == false else { return }
        library?.updateMusicVideoReference(songID: song.id, mvPath: nil)
        if currentSong?.id == song.id {
            currentSong?.mvPath = nil
        }
    }

    private func removeMusicVideoObservers() {
        if let observer = musicVideoTimeObserver, let player = musicVideoPlayer {
            player.removeTimeObserver(observer)
        }
        musicVideoTimeObserver = nil
        if let observer = musicVideoEndObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        musicVideoEndObserver = nil
        musicVideoStatusObservation?.invalidate()
        musicVideoStatusObservation = nil
        if let observer = musicVideoFailedObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        musicVideoFailedObserver = nil
    }

    private func stopMusicVideoPlayback(clearPlayer: Bool) {
        guard musicVideoPlayer != nil || isMusicVideoPlaybackActive || musicVideoStreamingLoader != nil else { return }
        musicVideoPlayer?.pause()
        removeMusicVideoObservers()
        if clearPlayer {
            musicVideoPlayer?.replaceCurrentItem(with: nil)
            musicVideoPlayer = nil
            musicVideoStreamingLoader?.invalidate()
            musicVideoStreamingLoader = nil
        }
        isMusicVideoPlaybackActive = false
    }

    private func showPlaybackError(_ message: String) {
        lastPlaybackError = message
        errorDismissTask?.cancel()
        let requestID = playID
        errorDismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self,
                  PlaybackErrorDismissalPolicy.shouldDismiss(
                    requestID: requestID,
                    activeRequestID: self.playID,
                    scheduledMessage: message,
                    currentMessage: self.lastPlaybackError,
                    isCancelled: Task.isCancelled
                  ) else { return }
            self.lastPlaybackError = nil
            self.errorDismissTask = nil
        }
    }

    private func beginPlaybackErrorScope() {
        errorDismissTask?.cancel()
        errorDismissTask = nil
        lastPlaybackError = nil
    }

    private func awaitFirstBuffer(
        from iteratorBox: BufferIteratorBox,
        timeoutSeconds: Int
    ) async throws -> AVAudioPCMBuffer? {
        let box: PCMBufferBox = try await withThrowingTaskGroup(of: PCMBufferBox.self) { group in
            group.addTask {
                let buffer = try await iteratorBox.next()
                return PCMBufferBox(value: buffer)
            }
            group.addTask {
                do {
                    try await Task.sleep(for: .seconds(timeoutSeconds))
                } catch {
                    return PCMBufferBox(value: nil)
                }
                throw CancellationError()
            }
            let first = try await group.next() ?? PCMBufferBox(value: nil)
            group.cancelAll()
            return first
        }
        return box.value
    }

    private func isNetworkTimeout(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorTimedOut {
            return true
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            return isNetworkTimeout(underlying)
        }
        return false
    }

    // MARK: - Playback Control

    func play(song: Song, caller: String = #fileID, callerLine: Int = #line) async {
        // Invalidate any pending operations immediately
        let id = UUID()
        playID = id
        beginPlaybackErrorScope()
        cancelCrossfadeAttempt()
        clearPendingPlaybackRecovery()
        let callerFile = (caller as NSString).lastPathComponent
        plog("▶️ play(song: \(song.title)) playID=\(id.uuidString.prefix(8)) FROM=\(callerFile):\(callerLine)")

        // "Stop at end of current track" is tied to the track that was
        // current when the user enabled it. If the user explicitly skips or
        // selects another song, cancel that stale lock. Natural completion is
        // handled before next() by handleTrackEnd / the gapless boundary.
        if let lockedID = sleepStopAfterSongID, lockedID != song.id {
            plog("🌙 Sleep-at-track-end cancelled by explicit track change")
            sleepStopAfterSongID = nil
        }

        // 切歌即取消上一首遗留的 MV 后台下载(保留 .partial 可续传),
        // 避免连续切歌积累多个全量下载并发抢带宽。
        sourceManager?.cancelMusicVideoDownloads(keeping: song)

        if AppleMusicPlaybackOwnershipPolicy.shouldAwaitCastingHandoff(
            isLocalPlayback: song.sourceID != AppleMusicLibraryService.systemSourceID,
            hasPendingHandoff: appleMusicCastingHandoffTask != nil
        ) {
            appleMusicPlaybackTask?.cancel()
            appleMusicPlaybackTask = nil
            appleMusicTimeoutTask?.cancel()
            appleMusicTimeoutTask = nil
            activeAppleMusicRequestID = nil
            stopAppleMusicMirror()
            AppServices.shared.appleMusic.stopAppleMusic()
            isPrimuseManagingAppleMusicQueue = false
            guard await awaitCastingHandoffForLocalPlayback(ownerID: id) else {
                return
            }
        }

        // Apple Music 歌走系统侧 ApplicationMusicPlayer (DRM 流不能经
        // AVAudioEngine 解), 跨 player 切换 — 先停我们自己的播放器再让
        // AppleMusicService 接手, audio session 系统自动 hand-off。
        if song.sourceID == AppleMusicLibraryService.systemSourceID {
            stopMusicVideoPlayback(clearPlayer: true)
            await playAppleMusicSong(song, playID: id)
            return
        }

        // Cast 模式 ── 走 RemoteRendererController 推到远端 renderer, 不动
        // 本地 audioEngine。next/previous 走到这里时同样路由。
        if castingController != nil {
            stopMusicVideoPlayback(clearPlayer: true)
            await castSong(song)
            return
        }

        // 上一首是 Apple Music → 切到本地: 先停 mirror task 并让系统侧停掉,
        // 避免 mirror 继续把 currentSong 改回 Apple Music 那首。
        if isAppleMusicMode
            || activeAppleMusicRequestID != nil
            || AppServices.shared.appleMusic.activePlaybackRequestID != nil {
            appleMusicPlaybackTask?.cancel()
            appleMusicPlaybackTask = nil
            appleMusicTimeoutTask?.cancel()
            appleMusicTimeoutTask = nil
            activeAppleMusicRequestID = nil
            stopAppleMusicMirror()
            AppServices.shared.appleMusic.stopAppleMusic()
        }
        isPrimuseManagingAppleMusicQueue = false

        // 切到新歌前主动触发上一首的 streaming session finalize, 让它有机会
        // 把 .partial 转成 final (如果缺口在 50MB 自动补齐阈值内)。
        if let prev = currentSong, prev.id != song.id {
            sourceManager?.finalizeStreamingSession(for: prev)
        }

        // Stop current playback
        decodingTask?.cancel()
        decodingTask = nil
        cancelGaplessTasks()
        audioEngine.stopPlayback()
        hasPreparedLocalPlayback = false
        stopTimeUpdater()
        stopMusicVideoPlayback(clearPlayer: true)

        // Show new song in UI immediately (before download)
        currentSong = song
        currentTime = 0
        duration = song.duration.sanitizedDuration
        isLoading = true
        isPlaying = false
        isAtTrackEnd = false
        plog("▶️ currentSong set to: \(song.title)")

        let musicVideoStartResult = await startMusicVideoPlaybackIfAvailable(for: song, playID: id)
        if case .started = musicVideoStartResult {
            return
        }

        do {
            let url = try await resolvedURL(for: song)
            // Check if another play was initiated while downloading
            guard playID == id else { return }
            await playFromURL(song: song, url: url, playID: id)
            if case .needsAudioFallback = musicVideoStartResult {
                markMusicVideoAudioFallbackIfNeeded(playID: id)
            }
        } catch {
            guard playID == id else { return }
            plog("Playback URL resolution error: \(error)")
            showPlaybackError(String(localized: "playback_error_connection"))
            isLoading = false
            if isSourceWideResolutionFailure(error) {
                plog("⏭️ Source-wide playback failure; skipping unavailable entries from source \(song.sourceID.prefix(8))")
                await autoAdvanceAfterFailure(skippingSourceID: song.sourceID)
                return
            }
            await autoAdvanceAfterFailure()
        }
    }

    /// Apple Music 歌路由 — 把猿音自家播放器停掉, 让 AppleMusicLibraryService
    /// 通过 ApplicationMusicPlayer 接手 DRM 流播放。currentSong **保留**为这首
    /// Apple Music 歌, 让 NowPlayingView / MiniPlayer 复用同一份实现; mirror
    /// task 会持续把 ApplicationMusicPlayer 的状态同步到 self 的字段。
    private func playAppleMusicSong(_ song: Song, playID id: UUID) async {
        // 停猿音自家 engine, audio session 让给 ApplicationMusicPlayer。
        decodingTask?.cancel(); decodingTask = nil
        cancelGaplessTasks()
        cancelCrossfadeAttempt()
        audioEngine.stopPlayback()
        hasPreparedLocalPlayback = false
        stopTimeUpdater()
        stopMusicVideoPlayback(clearPlayer: true)
        let appleMusic = AppServices.shared.appleMusic
        appleMusicPlaybackTask?.cancel()
        appleMusicPlaybackTask = nil
        appleMusicTimeoutTask?.cancel()
        appleMusicTimeoutTask = nil
        // Install the shared request generation before isLoading and before
        // the mirror's immediate first sync. This both clears retained state
        // and prevents any older lookup/preflight from publishing afterward.
        appleMusic.beginPlaybackRequest(id: id)
        activeAppleMusicRequestID = id
        beginPlaybackErrorScope()
        guard await prepareAppleMusicPlaybackHandoff(requestID: id),
              playID == id,
              activeAppleMusicRequestID == id else { return }
        currentSong = song
        currentTime = 0
        duration = song.duration
        isLoading = true
        isPlaying = false
        isAtTrackEnd = false

        // Primuse's visible queue remains the only ordering authority. Giving
        // MusicKit a separate multi-song context lets it diverge whenever the
        // user appends/reorders songs or mixes providers. MusicKit therefore
        // receives only the current DRM item for every Primuse queue.
        let selectedQueueEntryMatches = queueEntries.indices.contains(currentIndex)
            && (
                queueEntries[currentIndex].song.id == song.id
                    || queueEntries[currentIndex].song.filePath == song.filePath
            )
        isPrimuseManagingAppleMusicQueue = AppleMusicQueueOwnershipPolicy.shouldUsePrimuseQueue(
            selectedQueueEntryMatches: selectedQueueEntryMatches
        )
        if isPrimuseManagingAppleMusicQueue {
            appleMusic.prepareForPrimuseManagedQueue()
        } else {
            appleMusic.setAppleMusicShuffle(shuffleEnabled)
            appleMusic.setAppleMusicRepeat(repeatMode)
        }
        // Capture before starting the mirror: its immediate first sync may
        // still contain the previous MusicKit queue.
        let queueContext = isPrimuseManagingAppleMusicQueue
            ? [song]
            : queue.filter { $0.sourceID == AppleMusicLibraryService.systemSourceID }
        startAppleMusicMirror(requestID: id)
        let appleMusicLibrary = AppServices.shared.appleMusicLibrary

        // 4s 兜底必须先注册。Apple Music user-library sync 在缺 entitlement
        // 或系统账户服务异常时可能卡住；如果把 timeout 放在 await 之后,
        // UI 会永远停在 isLoading=true。
        appleMusicTimeoutTask = Task { @MainActor [weak self, songID = song.id] in
            try? await Task.sleep(for: .seconds(4))
            guard let self,
                  self.currentSong?.id == songID,
                  self.activeAppleMusicRequestID == id,
                  PlaybackRequestGenerationPolicy.shouldApplyResult(
                    requestID: id,
                    activeRequestID: self.playID,
                    isCancelled: Task.isCancelled
                  ),
                  AppServices.shared.appleMusic.isPlaybackRequestActive(id) else { return }
            let am = AppServices.shared.appleMusic
            switch am.playbackPhase(for: id) {
            case .started:
                self.isLoading = false
            case .failed(let playbackError):
                self.lastPlaybackError = playbackError
                self.isLoading = false
            case .pending:
                self.appleMusicPlaybackTask?.cancel()
                self.appleMusicPlaybackTask = nil
                let message = String(localized: "playback_error_apple_music_generic")
                am.failPlaybackRequest(id, message: message)
                self.isLoading = false
                self.lastPlaybackError = message
            case nil:
                return
            }
            self.appleMusicTimeoutTask = nil
        }

        // 不阻塞 play(song:) 调用方。成功后 AppleMusicService 的 mirror 会把
        // nowPlaying / progress 同步回来；失败或卡住由上面的 timeout 收口。
        let playbackTask = Task { @MainActor [weak self] in
            await appleMusicLibrary.play(
                primuseSong: song,
                queueContext: queueContext,
                requestID: id
            )
            guard let self,
                  self.activeAppleMusicRequestID == id,
                  self.playID == id else { return }
            self.appleMusicPlaybackTask = nil
        }
        appleMusicPlaybackTask = playbackTask
    }

    /// 启动 Apple Music 状态镜像 ── observation tracking 监听 appleMusic 的
     /// nowPlayingSong / isAppleMusicPlaying / currentPlaybackTime 等字段,
     /// 每次变化把值 mirror 到 self 的 currentSong / isPlaying / currentTime 等。
     /// 切回本地播放或 stop 时取消。
     private func startAppleMusicMirror(requestID: UUID) {
         appleMusicMirrorTask?.cancel()
         appleMusicMirrorGeneration &+= 1
         let generation = appleMusicMirrorGeneration
         let am = AppServices.shared.appleMusic
         guard am.isPlaybackRequestActive(requestID) else { return }
         appleMusicMirrorTask = Task { @MainActor [weak self] in
             while !Task.isCancelled {
                 await self?.awaitNextAppleMusicChange(am: am)
                 guard let self,
                       self.activeAppleMusicRequestID == requestID,
                       PlaybackRequestGenerationPolicy.shouldApplyResult(
                        requestID: requestID,
                        activeRequestID: self.playID,
                        isCancelled: Task.isCancelled
                       ),
                       am.isPlaybackRequestActive(requestID),
                       AppleMusicQueueMirrorPolicy.isActiveSession(
                        sessionGeneration: generation,
                        activeGeneration: self.appleMusicMirrorGeneration,
                        isCancelled: Task.isCancelled
                       ) else { return }
                 self.mirrorAppleMusicState(
                    sessionGeneration: generation,
                    requestID: requestID
                 )
             }
         }
         // 首次进 Apple Music 模式时主动 mirror 一次, 不用等下一个 polling tick。
         mirrorAppleMusicState(sessionGeneration: generation, requestID: requestID)
     }

     /// 注意必须 @MainActor 隔离 ── withObservationTracking 的 read 阶段
     /// 要跟它访问的 Observable 在同一 actor (这里是 appleMusic 即 @MainActor)。
     /// 之前写成 nonisolated + MainActor.assumeIsolated 在 Task 任意线程上
     /// 触发了 precondition trap → 启动 Apple Music 播放秒闪退 (见 PR / 日志)。
     private func awaitNextAppleMusicChange(am: AppleMusicService) async {
         await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
             withObservationTracking {
                 _ = am.nowPlayingSong?.id
                 _ = am.nowPlayingRawSongID
                 _ = am.isAppleMusicPlaying
                 _ = am.currentPlaybackTime
                 _ = am.currentDuration
                 _ = am.queueSongs.count
                 _ = am.repeatModeMirror
                 _ = am.shuffleEnabledMirror
                 _ = am.lastPlaybackError
                 _ = am.playbackRequestState
             } onChange: {
                 cont.resume()
             }
         }
     }

     private func stopAppleMusicMirror() {
         // Bump before cancellation. `stopAppleMusic()` immediately changes
         // observed values and may wake the old checked continuation before
         // its cancelled task has otherwise had a chance to exit.
         appleMusicMirrorGeneration &+= 1
         appleMusicMirrorTask?.cancel()
         appleMusicMirrorTask = nil
     }

     private func mirrorAppleMusicState(
        sessionGeneration: UInt64,
        requestID: UUID
     ) {
         // 用 appleMusic.nowPlayingSong 而不是 self.isAppleMusicMode 做 guard ──
         // 初次从 catalog 路径切到 Apple Music 时 currentSong 可能还是旧的本地
         // 歌, 等 mirror 第一次写入新值之后 isAppleMusicMode 才变 true。
         let am = AppServices.shared.appleMusic
         guard activeAppleMusicRequestID == requestID,
               PlaybackRequestGenerationPolicy.shouldApplyResult(
                requestID: requestID,
                activeRequestID: playID,
                isCancelled: false
               ),
               am.isPlaybackRequestActive(requestID),
               AppleMusicQueueMirrorPolicy.isActiveSession(
                sessionGeneration: sessionGeneration,
                activeGeneration: appleMusicMirrorGeneration,
                isCancelled: false
               ) else { return }
         guard let phase = am.playbackPhase(for: requestID) else { return }
         switch phase {
         case .pending:
             return
         case .failed(let playbackError):
             lastPlaybackError = playbackError
             isLoading = false
             isPlaying = false
             return
         case .started:
             lastPlaybackError = nil
             isLoading = false
         }
         guard let nps = am.nowPlayingSong else { return }
         isMirroringFromAppleMusic = true
         defer { isMirroringFromAppleMusic = false }

         // MusicKit owns the current song only for direct plays that did not
         // originate from Primuse's queue. Queued playback keeps the original
         // Song identity and currentIndex here.
         let pSong = AppServices.shared.appleMusicLibrary.canonicalPrimuseSong(for: nps)
         if let rawSongID = am.nowPlayingRawSongID, rawSongID != pSong.id {
             let aliasKey = "\(rawSongID)→\(pSong.id)"
             if rescuedAppleMusicLyricsAliases.insert(aliasKey).inserted {
                 Task {
                     await MetadataAssetStore.shared.preserveLyricsAlias(
                         fromSongID: rawSongID,
                         toSongID: pSong.id
                     )
                 }
             }
         }
         if !isPrimuseManagingAppleMusicQueue, pSong.id != currentSong?.id {
             currentSong = pSong
         }
         isPlaying = am.isAppleMusicPlaying
         // 首次播 (isLoading=true) 收到 playing 状态才清 isLoading,
         // 避免 polling 命中前 UI 一直显示 spinner。
         currentTime = am.currentPlaybackTime
         if am.currentDuration > 0 { duration = am.currentDuration }
         // A MusicKit queue can only describe Apple Music entries. Mirroring
         // it over a mixed queue used to discard thousands of local songs as
         // soon as shuffle landed on one Apple Music track.
         // MusicKit briefly publishes an empty queue while stopping or while a
         // new queue is being installed. An empty transient snapshot must not
         // erase Primuse's canonical queue; explicit stop/clear paths already
         // clear it intentionally.
         if AppleMusicQueueMirrorPolicy.shouldApplySnapshot(
            sessionGeneration: sessionGeneration,
            activeGeneration: appleMusicMirrorGeneration,
            isCancelled: false,
            primuseOwnsCanonicalQueue: isPrimuseManagingAppleMusicQueue,
            snapshotCount: am.queueSongs.count
         ) {
             let newIDs = am.queueSongs.map(\.id)
             if newIDs != queueEntries.map(\.song.id) {
                 queueEntries = am.queueSongs.map { QueueEntry(song: $0) }
             }
             if let currentID = currentSong?.id,
                let mirroredIndex = queueEntries.firstIndex(where: { $0.song.id == currentID }) {
                 currentIndex = mirroredIndex
             }
             if repeatMode != am.repeatModeMirror { repeatMode = am.repeatModeMirror }
             if shuffleEnabled != am.shuffleEnabledMirror { shuffleEnabled = am.shuffleEnabledMirror }
         }
     }

    /// Called when the one-item MusicKit queue reaches a terminal boundary.
    /// Primuse then advances its canonical queue, regardless of the next
    /// song's provider.
    func handleAppleMusicPlaybackEnded(requestID: UUID) {
        let appleMusic = AppServices.shared.appleMusic
        guard isPrimuseManagingAppleMusicQueue,
              isAppleMusicMode,
              activeAppleMusicRequestID == requestID,
              playID == requestID,
              appleMusic.isPlaybackRequestActive(requestID) else { return }
        Task { @MainActor [weak self] in
            guard let self,
                  self.activeAppleMusicRequestID == requestID,
                  self.playID == requestID,
                  AppServices.shared.appleMusic.isPlaybackRequestActive(requestID) else { return }
            await self.handleTrackEnd()
        }
    }

    func play(song: Song, from url: URL) async {
        // 与主 play(song:) 一致的路由: 投屏时推远端、Apple Music 镜像时先停镜像。
        // 否则本地 audioEngine 会与远端 renderer / 系统播放器同时出声, 且 mirror task
        // 仍会把 currentSong 改回 Apple Music 那首。
        let id = UUID()
        playID = id
        beginPlaybackErrorScope()
        cancelCrossfadeAttempt()
        clearPendingPlaybackRecovery()

        if AppleMusicPlaybackOwnershipPolicy.shouldAwaitCastingHandoff(
            isLocalPlayback: true,
            hasPendingHandoff: appleMusicCastingHandoffTask != nil
        ) {
            appleMusicPlaybackTask?.cancel()
            appleMusicPlaybackTask = nil
            appleMusicTimeoutTask?.cancel()
            appleMusicTimeoutTask = nil
            activeAppleMusicRequestID = nil
            stopAppleMusicMirror()
            AppServices.shared.appleMusic.stopAppleMusic()
            isPrimuseManagingAppleMusicQueue = false
            guard await awaitCastingHandoffForLocalPlayback(ownerID: id) else {
                return
            }
        }

        if castingController != nil {
            await castSong(song)
            return
        }
        if isAppleMusicMode
            || activeAppleMusicRequestID != nil
            || AppServices.shared.appleMusic.activePlaybackRequestID != nil {
            appleMusicPlaybackTask?.cancel()
            appleMusicPlaybackTask = nil
            appleMusicTimeoutTask?.cancel()
            appleMusicTimeoutTask = nil
            activeAppleMusicRequestID = nil
            stopAppleMusicMirror()
            AppServices.shared.appleMusic.stopAppleMusic()
        }
        isPrimuseManagingAppleMusicQueue = false
        decodingTask?.cancel()
        decodingTask = nil
        cancelGaplessTasks()
        audioEngine.stopPlayback()
        stopTimeUpdater()
        stopMusicVideoPlayback(clearPlayer: true)
        await playFromURL(song: song, url: url, playID: id)
    }

    private func playFromURL(song: Song, url: URL, playID id: UUID) async {
        plog("▶️ playFromURL(song: \(song.title)) playID=\(id.uuidString.prefix(8))")
        plog("▶️   URL: \(redactedURL(url))")
        plog("▶️   scheme=\(url.scheme ?? "nil") isFileURL=\(url.isFileURL) ext=\(url.pathExtension) format=\(song.fileFormat) duration=\(song.duration)")
        currentSong = song
        duration = song.duration.sanitizedDuration
        isLoading = true
        isPlaying = false
        hasPreparedLocalPlayback = false
        audioEngine.sampleTimeOffset = 0
        crossfadeTriggered = false; isCrossfading = false
        activeDecoderKind = .native
        var activeDSDMode: DSDPlaybackMode = .pcm

        let isRemoteURL = url.scheme == "http" || url.scheme == "https"
        let isCloudStream = url.scheme == SourceManager.cloudStreamingScheme

        let decoderAvailable: Bool
        if isRemoteURL || isCloudStream || nativeDecoder.canDecode(url: url) {
            decoderAvailable = true
        } else {
            decoderAvailable = await ffmpegCanDecodeOffMain(url)
        }
        guard decoderAvailable else {
            plog("Unsupported format: \(url.pathExtension)")
            isLoading = false
            await autoAdvanceAfterFailure()
            return
        }

        do {
            activeDSDMode = try await configureOutputPipeline(for: song, url: url)
            activeDSDPlaybackMode = activeDSDMode
            applySpatialAudioSettings()
            applyPlaybackRate()
            audioEffectsService.applySettings()
            equalizerService.applySettings()
            guard let outputFormat = audioEngine.outputFormat else {
                throw AudioDecoderError.decodingFailed("Audio engine not ready")
            }

            try audioEngine.start()

            // Reset volume immediately; apply ReplayGain asynchronously after playback starts
            audioEngine.resetPlayerVolume()

            // Cloud streaming: instead of downloading the whole file, build
            // an SFBInputSource whose reads go through HTTP Range +
            // sparse-on-disk cache. SFBAudioEngine reads from it like any
            // file and we get instant playback.
            let stream: AudioBufferStream
            if isRemoteURL {
                if FileFormatRouter.requiresCompleteLocalFile(song.fileFormat) {
                    plog("▶️ Decoder: FFmpeg full-download (custom formats require a local seekable stream)")
                    let cacheURL = playbackSettings.audioCacheEnabled ? sourceManager?.cacheURL(for: song) : nil
                    await playWithStreamingDownload(song: song, url: url, outputFormat: outputFormat, playID: id, cacheURL: cacheURL)
                    return
                }
                if SourceManager.isTranscodedStreamURL(url), assetReaderDecoder.canDecode(url: url) {
                    // 服务端转码流(Subsonic WMA→mp3, 大小未知): 走 AVAssetReader 渐进
                    // 解码。不按 song.fileSize 做 HTTP Range(会读越界), 也不写按
                    // 大小校验的持久缓存。
                    plog("▶️ Decoder: AVAssetReader (reason: server transcoded stream, progressive, unknown length) outputFormat: sr=\(outputFormat.sampleRate) ch=\(outputFormat.channelCount)")
                    await playWithFallbackDecoder(song: song, url: url, outputFormat: outputFormat, playID: id)
                    return
                }
                if let inputSource = await makeHTTPStreamingInputSource(for: song, url: url) {
                    plog("▶️ Decoder: HTTPRangePlaybackSource (reason: scheme=\(url.scheme ?? "?"), range-based HTTP streaming) cache=\(playbackSettings.audioCacheEnabled) outputFormat: sr=\(outputFormat.sampleRate) ch=\(outputFormat.channelCount)")
                    activeDecoderKind = .httpStream
                    stream = nativeDecoder.decode(from: inputSource, outputFormat: outputFormat, onResolveSourceLength: makeResolveLengthCallback(for: song))
                } else if isDLNACast(song), assetReaderDecoder.canDecode(url: url) {
                    // DLNA control points often push CGI/progressive URLs
                    // with no Content-Length. Full-download fallback waits
                    // for EOF before decoding, which leaves the sender stuck
                    // on loading. Let AVFoundation open the remote asset
                    // progressively before trying the legacy full download.
                    plog("▶️ Decoder: AVAssetReader (reason: DLNA URL has no range/fileSize, progressive remote fallback) outputFormat: sr=\(outputFormat.sampleRate) ch=\(outputFormat.channelCount)")
                    await playWithFallbackDecoder(song: song, url: url, outputFormat: outputFormat, playID: id)
                    return
                } else {
                    // Fallback for legacy rows / arbitrary URLs where fileSize is
                    // unknown. This preserves compatibility but still logs clearly
                    // that startup waits for a full download.
                    plog("▶️ Decoder: StreamingDownloadDecoder (reason: HTTP range unavailable or fileSize unknown, full-download fallback) outputFormat: sr=\(outputFormat.sampleRate) ch=\(outputFormat.channelCount)")
                    let cacheURL = playbackSettings.audioCacheEnabled ? sourceManager?.cacheURL(for: song) : nil
                    await playWithStreamingDownload(song: song, url: url, outputFormat: outputFormat, playID: id, cacheURL: cacheURL)
                    return
                }
            } else if isCloudStream, let manager = sourceManager,
               let inputSource = try? await manager.makeStreamingInputSource(
                   for: song,
                   cacheEnabled: playbackSettings.audioCacheEnabled
               ) {
                // 解码器选型: 自定义 cloudStreamingScheme (primuse-stream://)
                // 走 CloudPlaybackSource。它包装一层 SFBInputSource, SFB read
                // 时按需走 HTTP Range fetch, 配合 sparse cache 实现"边下边播"。
                // 适合云盘 (Baidu / Aliyun / OneDrive / Dropbox) 的 dlink
                // 流式播放 ── 这些场景下不能像 NAS 那样直接给 SFBAudioEngine
                // 一个稳定的 HTTPS URL。
                plog("▶️ Decoder: CloudPlaybackSource (reason: scheme=primuse-stream, range-based streaming) cache=\(playbackSettings.audioCacheEnabled) outputFormat: sr=\(outputFormat.sampleRate) ch=\(outputFormat.channelCount)")
                activeDecoderKind = .cloudStream
                stream = nativeDecoder.decode(from: inputSource, outputFormat: outputFormat, onResolveSourceLength: makeResolveLengthCallback(for: song))
            } else {
                // Local file path (or fallback when streaming setup failed)
                let reason = isCloudStream
                    ? "primuse-stream URL but inputSource setup failed, fallback to file path"
                    : "local file path (file:// scheme)"
                if await usesFFmpegDecoder(for: song, url: url) {
                    activeDecoderKind = .ffmpeg
                    plog("▶️ Decoder: FFmpeg (reason: \(reason)) outputFormat: sr=\(outputFormat.sampleRate) ch=\(outputFormat.channelCount)")
                    stream = ffmpegDecoder.decode(
                        from: url,
                        outputFormat: outputFormat,
                        onResolveSourceLength: makeResolveLengthCallback(for: song)
                    )
                } else {
                    plog("▶️ Decoder: NativeDecoder (reason: \(reason)) outputFormat: sr=\(outputFormat.sampleRate) ch=\(outputFormat.channelCount)")
                    stream = nativeDecoder.decode(
                        from: url,
                        outputFormat: outputFormat,
                        dsdMode: activeDSDMode,
                        onResolveSourceLength: makeResolveLengthCallback(for: song)
                    )
                }
            }
            let playbackStream = segmented(stream, for: song)
            let iteratorBox = BufferIteratorBox(playbackStream.makeAsyncIterator())

            // Await first buffer — ensures we have audio data before calling play()
            // Wrapped in a 35s timeout race so a hung cloud fetch (revoked
            // dlink that never errors out, account-banned network stall)
            // doesn't leave the play button spinning forever. The
            // CloudPlaybackSource serve has its own 30s per-chunk timeout
            // — this one is the outer safety net.
            let firstBuffer: AVAudioPCMBuffer
            do {
                guard let buffer = try await awaitFirstBuffer(
                    from: iteratorBox,
                    timeoutSeconds: Self.firstBufferTimeoutSeconds
                ) else {
                    // Empty stream — skip to next
                    guard playID == id else { return }
                    isLoading = false
                    await autoAdvanceAfterFailure()
                    return
                }
                guard playID == id else { return }
                firstBuffer = buffer
            } catch is CancellationError {
                guard !Task.isCancelled, playID == id else { return }
                // 云盘大文件逐 chunk 流式卡死(连接饥饿 / 冷文件 hydration)时,
                // 退回整文件渐进下载再试一次, 而不是直接报错跳过。
                if isCloudStream, await cloudFullDownloadFallback(song: song, outputFormat: outputFormat, playID: id) {
                    return
                }
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
                if activeDecoderKind == .httpStream {
                    if isDLNACast(song), assetReaderDecoder.canDecode(url: url) {
                        plog("↳ HTTP range decode failed before first buffer; trying DLNA progressive AssetReader fallback")
                        await playWithFallbackDecoder(song: song, url: url, outputFormat: outputFormat, playID: id)
                    } else {
                        plog("↳ HTTP range decode failed before first buffer; falling back to full download")
                        let cacheURL = playbackSettings.audioCacheEnabled ? sourceManager?.cacheURL(for: song) : nil
                        await playWithStreamingDownload(song: song, url: url, outputFormat: outputFormat, playID: id, cacheURL: cacheURL)
                    }
                } else if !isCloudStream {
                    let safeOutputFormat = preparePCMOutputAfterDoPFailure(
                        song: song,
                        url: url,
                        wasUsingDoP: activeDSDMode == .dop
                    ) ?? outputFormat
                    activeDSDPlaybackMode = .pcm
                    await playWithFallbackDecoder(song: song, url: url, outputFormat: safeOutputFormat, playID: id)
                } else if await cloudFullDownloadFallback(song: song, outputFormat: outputFormat, playID: id) {
                    return
                } else {
                    isLoading = false
                }
                return
            }

            // Schedule first buffer BEFORE play — playerNode has data ready
            plog("▶️ Decoder firstBuffer: kind=\(activeDecoderKind) frames=\(firstBuffer.frameLength) format=sr\(firstBuffer.format.sampleRate)/ch\(firstBuffer.format.channelCount)")
            plog("▶️ Engine state: outputFormat=sr\(outputFormat.sampleRate)/ch\(outputFormat.channelCount) mainVol=\(audioEngine.volume)")
            plog("▶️ Engine diagnostics: \(audioEngine.diagnosticInfo())")
            audioEngine.scheduleBuffer(firstBuffer)
            hasPreparedLocalPlayback = true
            audioEngine.play()
            plog("▶️ After play(): \(audioEngine.diagnosticInfo())")

            // Fetch duration asynchronously if not already known.
            // Skip for cloud-stream URLs — fileInfo opens via SFBAudioEngine
            // by URL, which doesn't understand the custom scheme. Duration
            // for cloud songs is filled in by MetadataBackfillService.
            if duration <= 0, !song.isCueTrack, !isCloudStream, activeDecoderKind != .httpStream {
                Task {
                    let decoder: any PrimuseAudioDecoder = self.activeDecoderKind == .ffmpeg
                        ? self.ffmpegDecoder : self.nativeDecoder
                    if let info = try? await decoder.fileInfo(for: url) {
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
            // Streaming URLs use persisted library tags; local files may
            // fall back to reading embedded tags from disk.
            let settings = playbackSettings.snapshot()
            if shouldApplyReplayGain(settings) {
                let decoderKind = activeDecoderKind
                Task { [id] in
                    await self.applyReplayGain(
                        for: song,
                        url: url,
                        mode: settings.replayGainMode,
                        allowFileRead: decoderKind != .cloudStream && decoderKind != .httpStream,
                        expectedPlayID: id,
                        expectedSongID: song.id
                    )
                }
            }

            // Background-cache file for offline playback (if enabled).
            // Cloud streaming already writes to the same cache file as
            // it goes — duplicating via cacheInBackground would just
            // race two writers on the same path.
            if playbackSettings.audioCacheEnabled, !isCloudStream, activeDecoderKind != .httpStream, !isDLNACast(song) {
                sourceManager?.cacheInBackground(song: song, cacheEnabled: playbackSettings.audioCacheEnabled)
            }

            // Prefetch next song
            prefetchNextSong()

            // Decode remaining buffers in background task (hold-last for completion callback)
            let gate = AsyncBufferGate(
                maxBufferedDuration: Self.decodedAudioLookahead,
                maxBufferCount: Self.maxInFlightDecodedBufferCount
            )
            decodingTask = Task { [id, iteratorBox, gate] in
                var lastBuffer: AVAudioPCMBuffer?
                var scheduledCount = 0
                var midStreamError = false
                defer { Task { await gate.drain() } }

                do {
                    while let buffer = try await iteratorBox.next() {
                        guard !Task.isCancelled, self.playID == id else { return }

                        if let prev = lastBuffer {
                            // Backpressure: block once the duration/count window
                            // is full so resident PCM tracks playback instead of
                            // the whole track piling into the node's unbounded queue.
                            let bufferedDuration = Self.decodedBufferDuration(prev)
                            await gate.acquire(duration: bufferedDuration)
                            guard !Task.isCancelled, self.playID == id else { return }
                            self.audioEngine.scheduleBuffer(
                                prev,
                                completionCallbackType: .dataConsumed
                            ) { _ in gate.release(duration: bufferedDuration) }
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
                    await self.scheduleDecodedFinalBuffer(finalBuffer, playID: id)
                }
            }
        } catch {
            guard !Task.isCancelled, playID == id else { return }
            plog("⚠️ Playback error for '\(song.title)': \(error.localizedDescription)")
            showPlaybackError(String(localized: "playback_error_decode"))
            isLoading = false
            // Auto-skip on decode failure (or stop under repeat-one
            // instead of looping a broken file).
            await autoAdvanceAfterFailure()
        }
    }

    /// 云盘逐 chunk 流式失败(首缓冲超时 / serve 报错)时的兜底: 用预授权直链
    /// 整文件渐进下载再试一次, 而不是直接报错跳过。直链解析仅 OneDrive 支持
    /// (resolveDirectDownloadURL 对其他源返回 nil), 故此兜底天然只对 OneDrive 生效。
    /// 返回 true 表示已接管(发起了下载或已切歌), 调用方不应再走默认错误分支。
    private func cloudFullDownloadFallback(song: Song, outputFormat: AVAudioFormat, playID id: UUID) async -> Bool {
        guard let manager = sourceManager,
              let directURL = await manager.resolveDirectDownloadURL(for: song) else { return false }
        guard playID == id else { return true }
        plog("↳ cloud chunked-stream failed; falling back to full progressive download (\(song.fileSize / 1_048_576)MB) via \(directURL.host ?? "?")")
        let cacheURL = playbackSettings.audioCacheEnabled ? manager.cacheURL(for: song) : nil
        await playWithStreamingDownload(song: song, url: directURL, outputFormat: outputFormat, playID: id, cacheURL: cacheURL)
        return true
    }

    /// Full-download fallback for remote URLs whose length is unknown or
    /// whose server rejects Range reads. Handles self-signed HTTPS
    /// certificates that AVAssetReader cannot.
    private func playWithStreamingDownload(
        song: Song, url: URL, outputFormat: AVAudioFormat,
        playID id: UUID, cacheURL: URL?
    ) async {
        let rawStream = streamingDecoder.decode(
            from: url,
            outputFormat: outputFormat,
            cacheFileURL: cacheURL,
            fileExtension: song.fileFormat.rawValue,
            onResolveSourceLength: makeResolveLengthCallback(for: song)
        )
        let stream = segmented(rawStream, for: song)
        let iteratorBox = BufferIteratorBox(stream.makeAsyncIterator())

        do {
            guard let firstBuffer = try await awaitFirstBuffer(
                from: iteratorBox,
                timeoutSeconds: Self.remoteFallbackFirstBufferTimeoutSeconds
            ) else {
                guard playID == id else { return }
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
            hasPreparedLocalPlayback = true
            audioEngine.play()
            plog("🌊 Engine diagnostics after play: \(audioEngine.diagnosticInfo())")

            // Fetch duration asynchronously if needed。SFBAudioDecoder 只支持
            // file:// URL,远程 HTTP/HTTPS URL 走到这条路径会抛 NSException
            // (NSAssertionHandler) 整 app SIGABRT,`try?` 接不住 ObjC 异常。
            // 远程流的 duration 由 streamingDownloadDecoder 自己解出来,这里跳过。
            if duration <= 0 && !song.isCueTrack && url.isFileURL {
                Task {
                    let decoder: any PrimuseAudioDecoder = await self.usesFFmpegDecoder(for: song, url: url)
                        ? self.ffmpegDecoder : self.nativeDecoder
                    if let info = try? await decoder.fileInfo(for: url) {
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
            let gate = AsyncBufferGate(
                maxBufferedDuration: Self.decodedAudioLookahead,
                maxBufferCount: Self.maxInFlightDecodedBufferCount
            )
            decodingTask = Task { [id, iteratorBox, gate] in
                var lastBuffer: AVAudioPCMBuffer?
                var scheduledCount = 0
                defer { Task { await gate.drain() } }
                do {
                    while let buffer = try await iteratorBox.next() {
                        guard !Task.isCancelled, self.playID == id else { return }
                        if let prev = lastBuffer {
                            let bufferedDuration = Self.decodedBufferDuration(prev)
                            await gate.acquire(duration: bufferedDuration)
                            guard !Task.isCancelled, self.playID == id else { return }
                            self.audioEngine.scheduleBuffer(
                                prev,
                                completionCallbackType: .dataConsumed
                            ) { _ in gate.release(duration: bufferedDuration) }
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
                    await self.scheduleDecodedFinalBuffer(finalBuffer, playID: id)
                }
            }
        } catch is CancellationError {
            guard !Task.isCancelled, playID == id else { return }
            plog("⚠️ StreamingDownload first-buffer timeout for '\(song.title)' after \(Self.remoteFallbackFirstBufferTimeoutSeconds)s")
            showPlaybackError(String(localized: "playback_error_connection"))
            isLoading = false
            await autoAdvanceAfterFailure()
        } catch {
            guard !Task.isCancelled, playID == id else { return }
            plog("⚠️ StreamingDownload failed for '\(song.title)': \(error.localizedDescription)")
            if isNetworkTimeout(error) {
                showPlaybackError(String(localized: "playback_error_connection"))
                isLoading = false
                await autoAdvanceAfterFailure()
                return
            }
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
        let formatRequiresCompleteLocalFile = FileFormatRouter.requiresCompleteLocalFile(fileFormat)
        let cueStart = song.cueStartTime
        let cueEnd = song.cueEndTime
        return { [weak self] resolved in
            guard resolved > 0 else { return }
            if cueStart == nil, AudioDurationPolicy.shouldIgnoreResolvedDuration(
                resolved: resolved,
                stored: storedDuration,
                fileSize: fileSize,
                bitRateKbps: bitRate,
                format: fileFormat,
                formatRequiresCompleteLocalFile: formatRequiresCompleteLocalFile
            ) {
                plog(String(format: "⚠️ Ignoring implausible SFB duration for '%@': %.1fs (stored %.1fs, size=%lldKB) — likely partial cloud read",
                            songTitle, resolved, storedDuration, fileSize / 1024))
                return
            }
            // The decoder reports the physical image length. Translate that
            // into a CUE segment length; for the final track the image end is
            // its implicit end boundary.
            let effectiveDuration: TimeInterval
            if let cueStart {
                effectiveDuration = max(0, (cueEnd ?? resolved) - cueStart)
            } else {
                effectiveDuration = resolved
            }
            guard effectiveDuration > 0 else { return }
            // Skip rewrite when the parser/backfill already had it
            // right (within 5%) — avoids library churn + UI thrash
            // for songs with a clean LAME header or m4a `mvhd`.
            let needsRewrite = storedDuration <= 0
                || abs(storedDuration - effectiveDuration) / max(effectiveDuration, 1) > 0.05
            guard needsRewrite else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.currentSong?.id == songID {
                    self.duration = effectiveDuration.sanitizedDuration
                    self.currentSong?.duration = effectiveDuration
                    self.updateNowPlayingInfo()
                }
                if let library = self.library, var existing = library.song(id: songID) {
                    existing.duration = effectiveDuration
                    library.replaceSong(existing)
                }
                plog(String(format: "🎵 Decoder resolved duration for '%@': %.1fs (was %.1fs) — rewrote library", songTitle, effectiveDuration, storedDuration))
            }
        }
    }

    private func decodeStream(
        for song: Song,
        url: URL,
        outputFormat: AVAudioFormat
    ) async -> AudioBufferStream? {
        let onResolveLength = makeResolveLengthCallback(for: song)

        let rawStream: AudioBufferStream?
        if url.scheme == SourceManager.cloudStreamingScheme {
            // Prefer fully-cached file if available (skips streaming overhead).
            if let cached = sourceManager?.cachedURL(for: song) {
                if await usesFFmpegDecoder(for: song, url: cached) {
                    rawStream = ffmpegDecoder.decode(
                        from: cached,
                        outputFormat: outputFormat,
                        onResolveSourceLength: onResolveLength
                    )
                } else {
                    rawStream = nativeDecoder.decode(
                        from: cached,
                        outputFormat: outputFormat,
                        onResolveSourceLength: onResolveLength
                    )
                }
                return rawStream.map { segmented($0, for: song) }
            }
            if FileFormatRouter.requiresCompleteLocalFile(song.fileFormat) { return nil }
            guard let manager = sourceManager,
                  let inputSource = try? await manager.makeStreamingInputSource(
                      for: song,
                      cacheEnabled: playbackSettings.audioCacheEnabled
                  ) else {
                return nil
            }
            rawStream = nativeDecoder.decode(from: inputSource, outputFormat: outputFormat, onResolveSourceLength: onResolveLength)
            return rawStream.map { segmented($0, for: song) }
        }
        if url.scheme == "http" || url.scheme == "https" {
            if let cached = sourceManager?.cachedURL(for: song) {
                if await usesFFmpegDecoder(for: song, url: cached) {
                    rawStream = ffmpegDecoder.decode(
                        from: cached,
                        outputFormat: outputFormat,
                        onResolveSourceLength: onResolveLength
                    )
                } else {
                    rawStream = nativeDecoder.decode(
                        from: cached,
                        outputFormat: outputFormat,
                        onResolveSourceLength: onResolveLength
                    )
                }
                return rawStream.map { segmented($0, for: song) }
            }
            if FileFormatRouter.requiresCompleteLocalFile(song.fileFormat) { return nil }
            if SourceManager.isTranscodedStreamURL(url), assetReaderDecoder.canDecode(url: url) {
                // 服务端转码流: 渐进 AVAssetReader, 不走已知大小的 Range / 缓存。
                rawStream = assetReaderDecoder.decode(from: url, outputFormat: outputFormat)
                return rawStream.map { segmented($0, for: song) }
            }
            if let inputSource = await makeHTTPStreamingInputSource(for: song, url: url) {
                rawStream = nativeDecoder.decode(from: inputSource, outputFormat: outputFormat, onResolveSourceLength: onResolveLength)
                return rawStream.map { segmented($0, for: song) }
            }
            rawStream = streamingDecoder.decode(
                from: url,
                outputFormat: outputFormat,
                cacheFileURL: nil,
                fileExtension: song.fileFormat.rawValue,
                onResolveSourceLength: onResolveLength
            )
            return rawStream.map { segmented($0, for: song) }
        }
        if await usesFFmpegDecoder(for: song, url: url) {
            rawStream = ffmpegDecoder.decode(
                from: url,
                outputFormat: outputFormat,
                onResolveSourceLength: onResolveLength
            )
        } else {
            rawStream = nativeDecoder.decode(
                from: url,
                outputFormat: outputFormat,
                onResolveSourceLength: onResolveLength
            )
        }
        return rawStream.map { segmented($0, for: song) }
    }

    private func segmented(
        _ stream: AudioBufferStream,
        for song: Song,
        sourceStartTime: TimeInterval = 0
    ) -> AudioBufferStream {
        AudioSegmentStream.trim(
            stream,
            startTime: song.cueStartTime.map { max(0, $0 - sourceStartTime) },
            endTime: song.cueEndTime.map { max(0, $0 - sourceStartTime) }
        )
    }

    private func makeHTTPStreamingInputSource(for song: Song, url: URL) async -> InputSource? {
        guard song.fileSize > 0,
              url.scheme == "http" || url.scheme == "https" else { return nil }

        let cacheEnabled = playbackSettings.audioCacheEnabled
        let cacheURL: URL
        let cacheRelativePath: String?
        if cacheEnabled, let sourceManager {
            cacheURL = sourceManager.cacheURL(for: song)
            let sanitized = song.filePath.replacingOccurrences(of: "/", with: "_")
            cacheRelativePath = "\(song.sourceID)/\(sanitized)"
            await AudioCacheManager.shared.evictIfNeeded(reserveBytes: song.fileSize)
        } else {
            cacheURL = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("primuse-http-\(song.id)")
            cacheRelativePath = nil
        }

        return CloudPlaybackSource.makeHTTPInputSource(
            song: song,
            url: url,
            totalLength: song.fileSize,
            cacheURL: cacheURL,
            persistOnComplete: cacheEnabled && sourceManager != nil,
            cacheRelativePath: cacheRelativePath
        )
    }

    /// Standalone music videos are commonly scanned before their container
    /// duration is known. Persist AVPlayer's authoritative value once so the
    /// library, queue, Now Playing state, and scrobble threshold agree.
    private func applyResolvedMusicVideoDuration(_ resolved: TimeInterval, playID id: UUID) {
        guard playID == id, resolved.isFinite, resolved > 0 else { return }
        let sanitized = resolved.sanitizedDuration
        duration = sanitized

        guard var song = currentSong, song.isStandaloneMusicVideo else { return }
        // The metadata backfill may have refreshed currentSong before this
        // observer fires, while the already-created scrobble session still
        // retains its original nil duration. Always offer the resolved value;
        // ScrobbleService deduplicates unchanged updates.
        ScrobbleService.shared.handlePlaybackDurationResolved(songID: song.id, duration: sanitized)
        let stored = song.duration.sanitizedDuration
        let needsRewrite = stored <= 0
            || abs(stored - sanitized) / max(sanitized, 1) > 0.05
        guard needsRewrite else { return }

        song.duration = sanitized
        currentSong = song
        if let queueIndex = queueEntries.firstIndex(where: { $0.song.id == song.id }) {
            queueEntries[queueIndex].song.duration = sanitized
        }

        if let library, var storedSong = library.song(id: song.id) {
            storedSong.duration = sanitized
            library.replaceSong(storedSong)
        }
        updateNowPlayingInfo()
        updatePlaybackState()
        plog(String(format: "🎞️ MV resolved real duration for '%@': %.1fs (was %.1fs)", song.title, sanitized, stored))
    }

    private func decoderKind(for song: Song, url: URL) async -> DecoderKind {
        if url.scheme == SourceManager.cloudStreamingScheme { return .cloudStream }
        if url.scheme == "http" || url.scheme == "https" {
            if SourceManager.isTranscodedStreamURL(url) { return .assetReader }
            return song.fileSize > 0 ? .httpStream : .streaming
        }
        return await usesFFmpegDecoder(for: song, url: url) ? .ffmpeg : .native
    }

    private func usesFFmpegDecoder(for song: Song, url: URL) async -> Bool {
        // Persisted format knowledge is authoritative and avoids re-reading a
        // dead mount merely to rediscover DTS-CD content.
        if FileFormatRouter.decoder(for: song.fileFormat) is FFmpegAudioDecoder {
            return true
        }
        if url.isFileURL, url.pathExtension.caseInsensitiveCompare("wav") == .orderedSame {
            return await ffmpegCanDecodeOffMain(url)
        }
        if nativeDecoder.canDecode(url: url) { return false }
        return await ffmpegCanDecodeOffMain(url)
    }

    private func ffmpegCanDecodeOffMain(_ url: URL) async -> Bool {
        do {
            return try await ffmpegDecoder.canDecodeAsync(url: url)
        } catch {
            // A failed/timeout probe is not proof that a WAV is PCM. Prefer the
            // bounded FFmpeg path so DTS carrier bytes can never reach Native
            // WAV playback as audible noise; the decode error remains visible.
            plog("FFmpeg content probe unavailable: \(error.localizedDescription)")
            return true
        }
    }

    private func prefetchNextSong() {
        prefetchTask?.cancel()
        // Prefetch 接下来几首,而不是只 1 首 —— 用户连续 next 切歌时
        // (4-5s/次), 单首 prefetch chain 来不及, 第 2、3 首切到时 partial
        // 还是空, SFB 现拉 1MB chunk 卡 2-3s。数量由 ST-01 设置页控制。
        let nextSongs = nextSongsInQueue(count: playbackSettings.prewarmQueueCount)
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
                    let pending = localPending ?? preparedNextShuffleRound()
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

    /// Broad fallback playback. A local file gets FFmpeg first; progressive
    /// remote media uses AVAssetReader because FFmpeg is intentionally opened
    /// only on complete, seekable files in this architecture.
    private func playWithFallbackDecoder(song: Song, url: URL, outputFormat: AVAudioFormat, playID id: UUID) async {
        guard playID == id else { return }
        let useFFmpeg: Bool
        if url.isFileURL {
            useFFmpeg = await ffmpegCanDecodeOffMain(url)
        } else {
            useFFmpeg = false
        }
        guard useFFmpeg || assetReaderDecoder.canDecode(url: url) else {
            plog("⚠️ No decoder available for '\(song.title)'")
            showPlaybackError(String(localized: "playback_error_format"))
            isLoading = false
            await autoAdvanceAfterFailure()
            return
        }

        let fallbackName = useFFmpeg ? "FFmpeg" : "AVAssetReader"
        plog("↳ \(fallbackName) fallback for '\(song.title)' url=\(url.scheme ?? "")://... ext=\(url.pathExtension)")

        let fallbackStream = segmented(
            useFFmpeg
                ? ffmpegDecoder.decode(from: url, outputFormat: outputFormat)
                : assetReaderDecoder.decode(from: url, outputFormat: outputFormat),
            for: song
        )
        let iteratorBox = BufferIteratorBox(fallbackStream.makeAsyncIterator())

        do {
            guard let firstBuffer = try await awaitFirstBuffer(
                from: iteratorBox,
                timeoutSeconds: Self.remoteFallbackFirstBufferTimeoutSeconds
            ) else {
                guard playID == id else { return }
                isLoading = false
                await autoAdvanceAfterFailure()
                return
            }
            guard playID == id else { return }

            plog("↳ \(fallbackName) firstBuffer: frames=\(firstBuffer.frameLength) format=sr\(firstBuffer.format.sampleRate)/ch\(firstBuffer.format.channelCount)")
            activeDecoderKind = useFFmpeg ? .ffmpeg : .assetReader
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
            hasPreparedLocalPlayback = true
            audioEngine.play()

            // Fetch duration asynchronously
            if duration <= 0 && !song.isCueTrack {
                Task {
                    let info: AudioFileInfo?
                    if useFFmpeg {
                        info = try? await self.ffmpegDecoder.fileInfo(for: url)
                    } else {
                        info = await self.assetReaderDecoder.fileInfo(for: url)
                    }
                    if let info {
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
            if shouldApplyReplayGain(settings), url.isFileURL {
                Task { [id] in
                    await self.applyReplayGain(
                        for: song,
                        url: url,
                        mode: settings.replayGainMode,
                        expectedPlayID: id,
                        expectedSongID: song.id
                    )
                }
            }

            // Background-cache file for offline playback
            if !isDLNACast(song) {
                sourceManager?.cacheInBackground(song: song, cacheEnabled: playbackSettings.audioCacheEnabled)
            }

            // Decode remaining buffers with track-end detection
            let gate = AsyncBufferGate(
                maxBufferedDuration: Self.decodedAudioLookahead,
                maxBufferCount: Self.maxInFlightDecodedBufferCount
            )
            decodingTask = Task { [id, iteratorBox, gate] in
                var lastBuffer: AVAudioPCMBuffer?
                defer { Task { await gate.drain() } }

                do {
                    while let buffer = try await iteratorBox.next() {
                        guard !Task.isCancelled, self.playID == id else { return }

                        if let prev = lastBuffer {
                            let bufferedDuration = Self.decodedBufferDuration(prev)
                            await gate.acquire(duration: bufferedDuration)
                            guard !Task.isCancelled, self.playID == id else { return }
                            self.audioEngine.scheduleBuffer(
                                prev,
                                completionCallbackType: .dataConsumed
                            ) { _ in gate.release(duration: bufferedDuration) }
                        }
                        lastBuffer = buffer
                    }
                } catch {
                    if !Task.isCancelled {
                        plog("⚠️ \(fallbackName) fallback decode error: \(error.localizedDescription)")
                    }
                }

                if let finalBuffer = lastBuffer {
                    guard !Task.isCancelled, self.playID == id else { return }
                    await self.scheduleDecodedFinalBuffer(finalBuffer, playID: id)
                }
            }
        } catch is CancellationError {
            guard !Task.isCancelled, playID == id else { return }
            plog("⚠️ \(fallbackName) fallback first-buffer timeout for '\(song.title)' after \(Self.remoteFallbackFirstBufferTimeoutSeconds)s")
            showPlaybackError(String(localized: "playback_error_connection"))
            isLoading = false
            await autoAdvanceAfterFailure()
        } catch {
            guard !Task.isCancelled, playID == id else { return }
            plog("⚠️ \(fallbackName) fallback also failed: \(error.localizedDescription)")
            isLoading = false
            await autoAdvanceAfterFailure()
        }
    }

    private func scheduleDecodedFinalBuffer(_ buffer: AVAudioPCMBuffer, playID id: UUID) async {
        guard shouldAttemptGapless(settings: playbackSettings.snapshot()),
              nextSongInQueue() != nil else {
            scheduleLastBuffer(buffer, playID: id)
            return
        }

        let transition = GaplessTransitionState(queueGeneration: queueGeneration)
        audioEngine.scheduleBuffer(
            buffer,
            completionCallbackType: .dataPlayedBack
        ) { [weak self, transition] _ in
            // .dataPlayedBack 在 playerNode.reset() / stopPlayback() 时也会
            // 同步 fire (任何 yield / 新 play / 主动切歌都会触发), id 是闭包
            // 捕获的旧 playID, 移到 guard 内才不会在 log 里产生误导事件。
            Task { @MainActor [weak self] in
                guard let self, self.playID == id else { return }
                plog("🔔 gapless boundary fired playID=\(id.uuidString.prefix(8))")
                await self.handleGaplessBoundary(transition: transition, playID: id)
            }
        }

        startGaplessPreparation(playID: id, transition: transition)
    }

    /// Schedules the held final buffer on whichever physical node currently
    /// owns the crossfaded song. The callback remains valid across node swap
    /// because the logical play ID is assigned when the fade begins.
    private func scheduleCrossfadeFinalBuffer(_ buffer: AVAudioPCMBuffer, playID id: UUID) {
        let completion: @Sendable (AVAudioPlayerNodeCompletionCallbackType) -> Void = { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.playID == id else { return }
                await self.handleTrackEnd()
            }
        }
        if crossfadeSwapDone {
            audioEngine.scheduleBuffer(
                buffer,
                completionCallbackType: .dataPlayedBack,
                completionHandler: completion
            )
        } else {
            audioEngine.scheduleCrossfadeBuffer(
                buffer,
                completionCallbackType: .dataPlayedBack,
                completionHandler: completion
            )
        }
    }

    private func scheduleCrossfadeFinalBufferAsFailure(
        _ buffer: AVAudioPCMBuffer,
        playID id: UUID
    ) {
        let completion: @Sendable (AVAudioPlayerNodeCompletionCallbackType) -> Void = { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.playID == id else { return }
                await self.autoAdvanceAfterFailure()
            }
        }
        if crossfadeSwapDone {
            audioEngine.scheduleBuffer(
                buffer,
                completionCallbackType: .dataPlayedBack,
                completionHandler: completion
            )
        } else {
            audioEngine.scheduleCrossfadeBuffer(
                buffer,
                completionCallbackType: .dataPlayedBack,
                completionHandler: completion
            )
        }
    }

    private func shouldAttemptGapless(settings: PlaybackSettings) -> Bool {
        guard settings.gaplessEnabled,
              !shouldUseCrossfade(settings),
              repeatMode != .one else { return false }

        if settings.outputMode == .highFidelity, let next = nextSongInQueue() {
            // A real sample-rate switch or DSD/DoP carrier change requires a
            // graph restart. Do not hide it behind the same-node gapless path.
            let currentIsDSD = currentSong.map { $0.fileFormat == .dsf || $0.fileFormat == .dff } ?? false
            let nextIsDSD = next.fileFormat == .dsf || next.fileFormat == .dff
            if currentIsDSD || nextIsDSD || currentSong?.sampleRate != next.sampleRate {
                return false
            }
        }

        if shouldBypassContinuousAudioTransition(for: nextSongInQueue()) {
            return false
        }

        switch activeDecoderKind {
        case .native, .ffmpeg, .httpStream, .cloudStream:
            return true
        case .streaming, .assetReader:
            return false
        }
    }

    private func shouldBypassContinuousAudioTransition(for song: Song?) -> Bool {
        guard let song,
              song.mvPath?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return false
        }
        // 独立 MV 始终走视频管线, 无论模式开关 / 车机路由都不该做 gapless 预取。
        if song.isStandaloneMusicVideo { return true }
        return isMusicVideoModeEnabled && !shouldForceAudioOnly
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
            Task { @MainActor [weak self] in
                guard let self, self.playID == id else { return }
                plog("🔔 lastBuffer dataPlayedBack fired playID=\(id.uuidString.prefix(8))")
                // In crossfade mode, only handle track end if crossfade wasn't triggered
                if self.shouldUseCrossfade(settings) && self.crossfadeTriggered { return }
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

    private func cancelGaplessTasks() {
        gaplessPreparationTask?.cancel()
        gaplessPreparationTask = nil
        gaplessFollowupTask?.cancel()
        gaplessFollowupTask = nil
    }

    func pause() {
        if isAppleMusicMode {
            AppServices.shared.appleMusic.togglePlayPauseAppleMusic()
            return
        }
        if isMusicVideoPlaybackActive {
            shouldResumeAfterInterruption = false
            syncPlaybackProgressFromEngine()
            musicVideoPlayer?.pause()
            // AVPlayer pause only stops presentation. The parallel full-file
            // MV cache task otherwise keeps downloading hundreds of MB while
            // the UI visibly says playback is paused. Preserve its .partial
            // file for a later resume/replay, but release network and battery
            // immediately.
            sourceManager?.cancelMusicVideoDownloads(keeping: nil)
            isPlaying = false
            updateNowPlayingInfo()
            updatePlaybackState()
            return
        }
        shouldResumeAfterInterruption = false
        // Align the engine's primary node with currentSong before capturing
        // the pause position during an already-committed fade.
        cancelCrossfadeAttempt(finishingCommittedTransition: true)
        syncPlaybackProgressFromEngine()
        audioEngine.pause()
        isPlaying = false
        stopTimeUpdater()
        updateNowPlayingInfo()
        updatePlaybackState()
    }

    func resume() {
        if isAppleMusicMode {
            AppServices.shared.appleMusic.togglePlayPauseAppleMusic()
            return
        }
        guard !isLoading, let song = currentSong else { return }
        if isMusicVideoPlaybackActive {
            _ = AudioSessionManager.shared.activatePlaybackSession()
            musicVideoPlayer?.play()
            isPlaying = true
            shouldResumeAfterInterruption = false
            updateNowPlayingInfo()
            updatePlaybackState()
            return
        }
        switch LocalPlaybackResumePolicy.action(
            isAtTrackEnd: isAtTrackEnd,
            needsRecovery: needsPlaybackRecovery,
            hasPreparedAudio: hasPreparedLocalPlayback
        ) {
        case .restartCurrentSong:
            // Track-end replay and retries after URL/authentication failure both
            // need a fresh resolve/decode pipeline; an empty player node cannot
            // be resumed.
            isAtTrackEnd = false
            Task { await play(song: song) }
            return
        case .recoverFromInterruption:
            seek(to: pendingRecoveryTime, startPlaying: true, isRecovery: true)
            return
        case .resumePreparedAudio:
            break
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

    // MARK: - Casting (DLNA Controller 路径)

    /// Apple Music cannot share playback ownership with a remote renderer.
    /// Every replacement request awaits the same in-flight Stop operation.
    func prepareAppleMusicPlaybackHandoff(requestID: UUID) async -> Bool {
        let appleMusic = AppServices.shared.appleMusic
        guard appleMusic.isPlaybackRequestPending(requestID),
              !Task.isCancelled else { return false }

        let handoffID: UUID
        let handoffTask: Task<Bool, Never>
        if let existingTask = appleMusicCastingHandoffTask {
            handoffID = appleMusicCastingHandoffID
            handoffTask = existingTask
        } else if let controller = castingController {
            castingPositionTask?.cancel()
            castingPositionTask = nil
            let renderer = castingRenderer
            castingRenderer = nil
            castingController = nil
            isPlaying = false

            handoffID = UUID()
            appleMusicCastingHandoffID = handoffID
            appleMusicCastingHandoffController = controller
            appleMusicCastingHandoffRenderer = renderer
            handoffTask = Task { @MainActor in
                do {
                    try await controller.stop()
                    plog("📡 Cast: stopped for Apple Music handoff")
                    return true
                } catch {
                    plog("⚠️ Cast stop during Apple Music handoff failed: \(error.localizedDescription)")
                    return false
                }
            }
            appleMusicCastingHandoffTask = handoffTask
        } else {
            return appleMusic.isPlaybackRequestPending(requestID)
                && !Task.isCancelled
        }

        let stopped = await handoffTask.value
        guard appleMusicCastingHandoffID == handoffID else { return false }
        if stopped {
            appleMusicCastingHandoffTask = nil
            appleMusicCastingHandoffController = nil
            appleMusicCastingHandoffRenderer = nil
            return appleMusic.isPlaybackRequestPending(requestID)
                && !Task.isCancelled
        }

        let requestIsCurrent = appleMusic.isPlaybackRequestPending(requestID)
        let hasCurrentPendingRequest: Bool
        if let activeRequestID = appleMusic.activePlaybackRequestID {
            hasCurrentPendingRequest = appleMusic.isPlaybackRequestPending(activeRequestID)
        } else {
            hasCurrentPendingRequest = false
        }
        let handoffStillOwnsAudio = activeAppleMusicRequestID == requestID
            && playID == requestID
        // A superseded waiter leaves the failed result installed for the newer
        // request. Restore only while this handoff still owns playback; a local
        // selection or explicit Stop must never resurrect the old renderer.
        if requestIsCurrent || (!hasCurrentPendingRequest && handoffStillOwnsAudio) {
            if castingController == nil,
               let controller = appleMusicCastingHandoffController {
                castingRenderer = appleMusicCastingHandoffRenderer
                castingController = controller
                startCastingPolling()
            }
            appleMusicCastingHandoffTask = nil
            appleMusicCastingHandoffController = nil
            appleMusicCastingHandoffRenderer = nil
            appleMusicCastingHandoffID = UUID()
            if requestIsCurrent {
                appleMusic.failPlaybackRequest(
                    requestID,
                    message: String(localized: "playback_error_apple_music_generic")
                )
            }
        }
        return false
    }

    private func clearAppleMusicCastingHandoff(
        id handoffID: UUID,
        invalidateWaiters: Bool
    ) {
        guard appleMusicCastingHandoffID == handoffID else { return }
        appleMusicCastingHandoffTask = nil
        appleMusicCastingHandoffController = nil
        appleMusicCastingHandoffRenderer = nil
        if invalidateWaiters {
            appleMusicCastingHandoffID = UUID()
        }
    }

    /// A local selection made while the renderer Stop is in flight must wait
    /// for that same operation. Starting AVAudioEngine first would briefly (or,
    /// on Stop failure, indefinitely) play on both outputs.
    private func awaitCastingHandoffForLocalPlayback(ownerID: UUID) async -> Bool {
        guard let handoffTask = appleMusicCastingHandoffTask else { return true }
        let handoffID = appleMusicCastingHandoffID
        let stopped = await handoffTask.value
        guard playID == ownerID,
              appleMusicCastingHandoffID == handoffID else { return false }
        if stopped {
            clearAppleMusicCastingHandoff(id: handoffID, invalidateWaiters: false)
            return true
        }

        if castingController == nil,
           let controller = appleMusicCastingHandoffController {
            castingRenderer = appleMusicCastingHandoffRenderer
            castingController = controller
            startCastingPolling()
        }
        clearAppleMusicCastingHandoff(id: handoffID, invalidateWaiters: true)
        isLoading = false
        showPlaybackError(String(localized: "playback_error_connection"))
        return false
    }

    /// `stop()` is synchronous, so finish the already-started renderer Stop in
    /// an owner-scoped task. A failed first command gets one best-effort retry,
    /// but the old renderer is never restored into stopped UI state.
    private func finishCastingHandoffForStop(ownerID: UUID) {
        guard let handoffTask = appleMusicCastingHandoffTask else { return }
        let handoffID = appleMusicCastingHandoffID
        let controller = appleMusicCastingHandoffController
        Task { @MainActor [weak self] in
            let stopped = await handoffTask.value
            guard let self,
                  self.playID == ownerID,
                  self.appleMusicCastingHandoffID == handoffID else { return }
            if !stopped, let controller {
                do {
                    try await controller.stop()
                    plog("📡 Cast: stopped on explicit-stop retry")
                } catch {
                    plog("⚠️ Cast explicit-stop retry failed: \(error.localizedDescription)")
                }
            }
            guard self.playID == ownerID,
                  self.appleMusicCastingHandoffID == handoffID else { return }
            self.clearAppleMusicCastingHandoff(
                id: handoffID,
                invalidateWaiters: true
            )
        }
    }

    /// 开始投屏到远端 renderer ── 本地立刻停, 把当前歌推过去续播 (从当前
    /// 进度起 seek)。后续 togglePlayPause / next / previous / seek 全部路由到
    /// RemoteRendererController。Apple Music DRM 歌无法投屏, 调用前 caller 应
    /// 自己 disable 按钮。
    func startCasting(to renderer: RemoteRenderer) async {
        let hasActiveAppleMusicRequest = activeAppleMusicRequestID != nil
            || AppServices.shared.appleMusic.activePlaybackRequestID != nil
            || appleMusicCastingHandoffTask != nil
        guard AppleMusicPlaybackOwnershipPolicy.canStartCasting(
            isAppleMusicMode: isAppleMusicMode,
            hasActivePlaybackRequest: hasActiveAppleMusicRequest
        ) else {
            plog("⚠️ Cast: Apple Music playback ownership is active or pending, ignored")
            return
        }
        // During a committed fade currentSong already names the incoming
        // track, while currentTime is intentionally frozen. Complete the node
        // swap first so the renderer resumes the right track at its real time.
        cancelCrossfadeAttempt(finishingCommittedTransition: true)
        syncPlaybackProgressFromEngine()
        let resumeSong = currentSong
        let resumeTime = currentTime
        let wasPlaying = isPlaying

        // 1. 本地停 (audioEngine + decoding task), audio session 让出去
        appleMusicCastingHandoffID = UUID()
        appleMusicCastingHandoffTask = nil
        appleMusicCastingHandoffController = nil
        appleMusicCastingHandoffRenderer = nil
        playID = UUID()
        beginPlaybackErrorScope()
        decodingTask?.cancel(); decodingTask = nil
        cancelGaplessTasks()
        cancelCrossfadeAttempt()
        audioEngine.stopPlayback()
        hasPreparedLocalPlayback = false
        stopMusicVideoPlayback(clearPlayer: true)
        stopTimeUpdater()
        isPlaying = false

        // 2. 切换 cast 状态 + 启动 controller
        castingRenderer = renderer
        castingController = RemoteRendererController(renderer: renderer)
        plog("📡 Cast: started → \(renderer.friendlyName)")

        // 3. 推当前歌到 renderer + seek 到 resumeTime + 自动 play
        if let song = resumeSong {
            await castSong(song, startAt: resumeTime, autoPlay: wasPlaying)
        }
        // 4. 启动 1Hz 状态轮询
        startCastingPolling()
    }

    /// 停投屏 ── controller stop + 本地从同一首歌当前进度续播 (用户期望)。
    /// 如果 controller 已经断 / 出错, 也强制清状态。
    func stopCasting() async {
        castingPositionTask?.cancel(); castingPositionTask = nil
        let controller = castingController
        let resumeSong = currentSong
        let resumeTime = currentTime
        let shouldResumeLocally = isPlaying
        castingRenderer = nil
        castingController = nil

        if let controller {
            try? await controller.stop()
        }
        plog("📡 Cast: stopped, resuming local from \(resumeTime)s")

        if let song = resumeSong {
            await play(song: song)
            if resumeTime > 1 || !shouldResumeLocally {
                // play 完成后再 seek; 给一点 buffer 时间
                try? await Task.sleep(for: .milliseconds(300))
                seek(to: max(0, resumeTime), startPlaying: shouldResumeLocally)
            }
        }
    }

    /// cast 模式下播指定歌 ── 解析 URL → 推 SetAVTransportURI → Play → 可选 Seek。
    /// 失败不抛错, 只 log + 保持 cast 状态让用户能手动重试。
    private func castSong(_ song: Song, startAt seconds: TimeInterval = 0, autoPlay: Bool = true) async {
        guard let controller = castingController else { return }
        currentSong = song
        currentTime = seconds
        duration = song.duration.sanitizedDuration
        do {
            let uri = try await resolveCastURI(for: song)
            try await controller.setAVTransportURI(uri: uri.absoluteString,
                                                    title: song.title,
                                                    artist: song.artistName)
            if autoPlay {
                try await controller.play()
                isPlaying = true
            }
            if seconds > 0 {
                try? await Task.sleep(for: .milliseconds(200))
                try? await controller.seek(toSeconds: seconds)
            }
            plog("📡 Cast: '\(song.title)' → \(controller.renderer.friendlyName)")
        } catch {
            plog("⚠️ Cast playback failed for '\(song.title)': \(error.localizedDescription)")
            isPlaying = false
        }
    }

    /// 给 renderer 拿一个它能 HTTP GET 的 URL:
    /// - file:// (本地 / cached): 注册到 DLNAMediaServer, 返回 http://<iphone>:49160/<token>/...
    /// - https / http (NAS / Cloud HTTP source): 直接给, renderer 拉 (前提同 LAN 或公网可达)
    /// - primuse-stream:// (range-fetch cloud): 当前不支持 cast, 抛错让 caller 提示用户先离线下载
    private func resolveCastURI(for song: Song) async throws -> URL {
        let url = try await resolvedURL(for: song)
        if url.isFileURL {
            let name = (song.title.isEmpty ? "track" : song.title) + "." + (url.pathExtension.isEmpty ? "mp3" : url.pathExtension)
            return try DLNAMediaServer.shared.registerFile(localURL: url, suggestedName: name)
        }
        if url.scheme == "http" || url.scheme == "https" {
            return url
        }
        throw NSError(domain: "Primuse.DLNA", code: -10,
                      userInfo: [NSLocalizedDescriptionKey: "Source \"\(song.title)\" needs offline download before casting (scheme=\(url.scheme ?? "?"))"])
    }

    private func startCastingPolling() {
        castingPositionTask?.cancel()
        castingPositionTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, let controller = self.castingController else { break }
                do {
                    let pos = try await controller.getPositionInfo()
                    if pos.currentTime >= 0 { self.currentTime = pos.currentTime }
                    if pos.duration > 0 { self.duration = pos.duration }
                    let state = try await controller.getTransportInfo()
                    self.isPlaying = (state == "PLAYING")
                } catch {
                    // 轮询失败 (renderer 断网 / 关机) 不立刻退出 cast, 给 3 次重试机会
                    plog("⚠️ Cast polling error: \(error.localizedDescription)")
                }
            }
        }
    }

    func togglePlayPause() {
        if isAppleMusicMode {
            AppServices.shared.appleMusic.togglePlayPauseAppleMusic()
            return
        }
        if isCastingMode, let controller = castingController {
            Task { [isPlaying] in
                do {
                    if isPlaying {
                        try await controller.pause()
                    } else {
                        try await controller.play()
                    }
                } catch {
                    plog("⚠️ Cast togglePlayPause failed: \(error.localizedDescription)")
                }
            }
            return
        }
        if isPlaying { pause() } else { resume() }
    }

    func stop() {
        let stopOwnerID = UUID()
        playID = stopOwnerID
        beginPlaybackErrorScope()
        finishCastingHandoffForStop(ownerID: stopOwnerID)
        if isAppleMusicMode
            || activeAppleMusicRequestID != nil
            || AppServices.shared.appleMusic.activePlaybackRequestID != nil {
            appleMusicPlaybackTask?.cancel()
            appleMusicPlaybackTask = nil
            appleMusicTimeoutTask?.cancel()
            appleMusicTimeoutTask = nil
            activeAppleMusicRequestID = nil
            AppServices.shared.appleMusic.stopAppleMusic()
            stopAppleMusicMirror()
            isPrimuseManagingAppleMusicQueue = false
            currentSong = nil
            currentTime = 0
            duration = 0
            isPlaying = false
            isLoading = false
            queueEntries = []
            return
        }
        // 主动结束当前 streaming session (切走 / 用户点停止时), 让 .partial
        // 有机会转 final。
        if let cur = currentSong {
            sourceManager?.finalizeStreamingSession(for: cur)
        }
        // Invalidate buffer completion callbacks before stop/reset fires them.
        decodingTask?.cancel()
        decodingTask = nil
        cancelGaplessTasks()
        cancelCrossfadeAttempt()
        audioEngine.stopPlayback()
        hasPreparedLocalPlayback = false
        audioEngine.resetPlayerVolume()
        stopMusicVideoPlayback(clearPlayer: true)
        sourceManager?.cancelMusicVideoDownloads(keeping: nil)
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
        // Invalidate the completed playback before stopping the node. The
        // safety-net timer and AVAudioPlayerNode's .dataPlayedBack callback can
        // arrive a few milliseconds apart for the same track. Without this,
        // the second callback re-enters handleTrackEnd(); most importantly it
        // can clear a "stop after this song" decision and advance the queue.
        if AppleMusicPlaybackOwnershipPolicy.shouldInvalidatePlayIDAtTrackEnd(
            isAppleMusicMode: isAppleMusicMode,
            hasActivePlaybackRequest: activeAppleMusicRequestID != nil
                || AppServices.shared.appleMusic.activePlaybackRequestID != nil
        ) {
            playID = UUID()
        }

        // 自然播完一首歌, 触发 finalize —— 这是 .partial → final 最关键的
        // 时机, 用户期望「听完一整首」就该是完整缓存。
        if let cur = currentSong {
            sourceManager?.finalizeStreamingSession(for: cur)
        }
        decodingTask?.cancel()
        decodingTask = nil
        cancelGaplessTasks()
        cancelCrossfadeAttempt()
        audioEngine.stopPlayback()
        hasPreparedLocalPlayback = false
        audioEngine.resetPlayerVolume()
        stopMusicVideoPlayback(clearPlayer: false)
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
        if isAppleMusicMode && !isPrimuseManagingAppleMusicQueue {
            AppServices.shared.appleMusic.skipToNextAppleMusic()
            return
        }
        guard !queue.isEmpty else { return }
        let callerFile = (caller as NSString).lastPathComponent
        plog("⏭️ next() called FROM=\(callerFile):\(callerLine) currentIndex=\(currentIndex) queueCount=\(queue.count)")
        if queue.count == 1, shuffleEnabled, repeatMode == .off {
            _ = extendExhaustedShuffleFromLibrary()
        }
        guard ManualQueueAdvancePolicy.shouldAdvance(
            queueCount: queue.count,
            repeatMode: repeatMode,
            shuffleEnabled: shuffleEnabled,
            hasSuccessor: nextSongInQueue() != nil
        ) else {
            plog("⏭️ next: no successor in repeat-off single-song queue; keeping current playback")
            return
        }
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
        if isAppleMusicMode && !isPrimuseManagingAppleMusicQueue {
            // 跟本地行为一致 ── 播放进度过 3s 时倒回开头, 否则跳上一首。
            if currentTime > 3 {
                AppServices.shared.appleMusic.seekAppleMusic(to: 0)
            } else {
                AppServices.shared.appleMusic.skipToPreviousAppleMusic()
            }
            return
        }
        guard !queue.isEmpty else { return }
        if currentTime > 3 {
            seek(to: 0)
            return
        }
        if shuffleEnabled {
            if shuffledIndices.isEmpty {
                currentIndex = 0
            } else {
                // 先把 shufflePosition 夹回合法区间再回退: 队列增删 / playFromQueue
                // 未命中 firstIndex 等情况会让 shufflePosition 与 shuffledIndices 失同步,
                // 直接下标可能越界崩溃。
                let clamped = min(max(0, shufflePosition), shuffledIndices.count - 1)
                shufflePosition = max(0, clamped - 1)
                currentIndex = shuffledIndices[shufflePosition]
            }
        } else {
            currentIndex = currentIndex > 0 ? currentIndex - 1 : queue.count - 1
        }
        await play(song: queue[currentIndex])
    }

    private var seekTimeOffset: TimeInterval = 0

    func seek(to time: TimeInterval, startPlaying: Bool? = nil, isRecovery: Bool = false) {
        if isAppleMusicMode {
            AppServices.shared.appleMusic.seekAppleMusic(to: TimeInterval.sanitized(time))
            return
        }
        if isCastingMode, let controller = castingController {
            let target = TimeInterval.sanitized(time)
            currentTime = target
            Task {
                do { try await controller.seek(toSeconds: target) } catch {
                    plog("⚠️ Cast seek failed: \(error.localizedDescription)")
                }
            }
            return
        }
        // A full-download streaming decoder can only seek after its completed
        // file has entered the playback cache. A user scrub must leave the
        // still-running node untouched, but interruption recovery cannot be
        // rejected the same way: the system has already stopped that node and
        // every later play command would otherwise return through this guard.
        if activeDecoderKind == .streaming, let song = currentSong {
            let decision = FullDownloadSeekPolicy.decision(
                hasSeekableFile: sourceManager?.cachedURL(for: song) != nil,
                isInterruptionRecovery: isRecovery
            )
            switch decision {
            case .proceed:
                break
            case .keepCurrentPlayback:
                plog("⚠️ Seek: streaming song not cached yet, leaving playback unchanged")
                return
            case .restartCurrentSong:
                plog("🔄 Recovery: streaming song has no seekable cache; restarting current song")
                clearPendingPlaybackRecovery()
                Task { await play(song: song) }
                return
            }
        }
        let previousTime = currentTime
        let requestedTime = TimeInterval.sanitized(time)
        let safeDuration = duration.sanitizedDuration
        let targetTime = safeDuration > 0 ? min(requestedTime, safeDuration) : requestedTime
        if isMusicVideoPlaybackActive {
            let shouldStartPlaying = startPlaying ?? isPlaying
            currentTime = targetTime
            isLoading = true
            isAtTrackEnd = false
            // 默认 tolerance —— 视频精确 seek 要重解整个 GOP, 拖进度条会
            // 明显顿挫; 落点由 periodic observer 回写, 进度条自然对齐。
            musicVideoPlayer?.seek(
                to: CMTime(seconds: targetTime, preferredTimescale: 600)
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.isLoading = false
                    if shouldStartPlaying {
                        self.musicVideoPlayer?.play()
                        self.isPlaying = true
                    } else {
                        self.musicVideoPlayer?.pause()
                        self.isPlaying = false
                    }
                    if isRecovery { self.clearPendingPlaybackRecovery() }
                    self.updateNowPlayingInfo()
                    self.updatePlaybackState()
                }
            }
            updateNowPlayingInfo()
            return
        }
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
        cancelGaplessTasks()
        cancelCrossfadeAttempt()
        audioEngine.stopPlayback()
        hasPreparedLocalPlayback = false
        stopTimeUpdater()

        // Restore state that stopPlayback clears
        currentSong = song
        currentTime = targetTime
        duration = savedDuration

        Task {
            do {
                let url = try await resolvedURL(for: song)
                guard playID == id else { return }
                activeDSDPlaybackMode = try await configureOutputPipeline(for: song, url: url)
                applySpatialAudioSettings()
                applyPlaybackRate()
                guard let outputFormat = audioEngine.outputFormat else { return }
                try audioEngine.start()

                let settings = playbackSettings.snapshot()
                if shouldApplyReplayGain(settings) {
                    await applyReplayGain(
                        for: song,
                        url: url,
                        mode: settings.replayGainMode,
                        allowFileRead: activeDecoderKind != .cloudStream && activeDecoderKind != .httpStream,
                        expectedPlayID: id,
                        expectedSongID: song.id
                    )
                }

                // Use the same decoder that was used for initial playback.
                // For streaming, require the cached local file — can't seek in remote streams.
                var seekURL: URL
                var seekDecoderKind = activeDecoderKind
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

                // Range-backed cloud/HTTP InputSources can expose byte seeking
                // while a format decoder still rejects PCM seeking. Never fall
                // back to decoding millions of frames just to reach a large
                // target. Complete the normal LRU cache once, then seek the
                // local file with FFmpeg/native random access.
                if (activeDecoderKind == .cloudStream || activeDecoderKind == .httpStream),
                   sourceManager?.cachedURL(for: song) == nil,
                   playbackSettings.audioCacheEnabled,
                   let cached = await sourceManager?.materializeCachedURLForSeeking(for: song) {
                    guard playID == id else { return }
                    seekURL = cached
                    seekDecoderKind = await ffmpegCanDecodeOffMain(cached) ? .ffmpeg : .native
                    activeDecoderKind = seekDecoderKind
                    plog("📍 Seek materialized remote audio to local cache; decoder=\(seekDecoderKind)")
                }
                let rawStream: AudioBufferStream
                let onResolveLength = makeResolveLengthCallback(for: song)
                var decoderPerformedSeek = false
                var decoderSourceStartTime: TimeInterval = 0
                let physicalSeekTime = max(
                    0,
                    (song.cueStartTime ?? 0) + targetTime
                )
                switch seekDecoderKind {
                case .native:
                    decoderPerformedSeek = true
                    decoderSourceStartTime = physicalSeekTime
                    rawStream = nativeDecoder.decode(
                        from: seekURL,
                        outputFormat: outputFormat,
                        dsdMode: activeDSDPlaybackMode,
                        startingAt: physicalSeekTime,
                        onResolveSourceLength: onResolveLength
                    )
                case .streaming:
                    // Custom formats enter through the full-download fallback.
                    // Once cached, FFmpeg can seek at the demuxer level.
                    if await usesFFmpegDecoder(for: song, url: seekURL) {
                        decoderPerformedSeek = true
                        decoderSourceStartTime = physicalSeekTime
                        rawStream = ffmpegDecoder.decode(
                            from: seekURL,
                            outputFormat: outputFormat,
                            startingAt: physicalSeekTime,
                            onResolveSourceLength: onResolveLength
                        )
                    } else {
                        decoderPerformedSeek = true
                        decoderSourceStartTime = physicalSeekTime
                        rawStream = nativeDecoder.decode(
                            from: seekURL,
                            outputFormat: outputFormat,
                            startingAt: physicalSeekTime,
                            onResolveSourceLength: onResolveLength
                        )
                    }
                case .ffmpeg:
                    decoderPerformedSeek = true
                    decoderSourceStartTime = physicalSeekTime
                    rawStream = ffmpegDecoder.decode(
                        from: seekURL,
                        outputFormat: outputFormat,
                        startingAt: physicalSeekTime,
                        onResolveSourceLength: onResolveLength
                    )
                case .httpStream:
                    if let cached = sourceManager?.cachedURL(for: song) {
                        decoderPerformedSeek = true
                        decoderSourceStartTime = physicalSeekTime
                        rawStream = nativeDecoder.decode(
                            from: cached,
                            outputFormat: outputFormat,
                            dsdMode: .pcm,
                            startingAt: physicalSeekTime,
                            onResolveSourceLength: onResolveLength
                        )
                    } else if let inputSource = await makeHTTPStreamingInputSource(for: song, url: url) {
                        decoderPerformedSeek = true
                        decoderSourceStartTime = physicalSeekTime
                        rawStream = nativeDecoder.decode(
                            from: inputSource,
                            outputFormat: outputFormat,
                            startingAt: physicalSeekTime,
                            onResolveSourceLength: onResolveLength
                        )
                    } else {
                        plog("⚠️ Seek: failed to build HTTP streaming InputSource")
                        isLoading = false
                        return
                    }
                case .cloudStream:
                    // Build a fresh InputSource for the seek session. The
                    // sparse cache file from the prior session is reused
                    // (SFB reads will hit local for any byte range we've
                    // already fetched, fall through to network for the
                    // rest). If the song has since been fully downloaded
                    // and renamed to the canonical path, prefer that.
                    if let cached = sourceManager?.cachedURL(for: song) {
                        decoderPerformedSeek = true
                        decoderSourceStartTime = physicalSeekTime
                        rawStream = nativeDecoder.decode(
                            from: cached,
                            outputFormat: outputFormat,
                            dsdMode: .pcm,
                            startingAt: physicalSeekTime,
                            onResolveSourceLength: onResolveLength
                        )
                    } else if let manager = sourceManager,
                              let inputSource = try? await manager.makeStreamingInputSource(
                                  for: song,
                                  cacheEnabled: playbackSettings.audioCacheEnabled
                              ) {
                        decoderPerformedSeek = true
                        decoderSourceStartTime = physicalSeekTime
                        rawStream = nativeDecoder.decode(
                            from: inputSource,
                            outputFormat: outputFormat,
                            startingAt: physicalSeekTime,
                            onResolveSourceLength: onResolveLength
                        )
                    } else {
                        plog("⚠️ Seek: failed to build cloud streaming InputSource")
                        isLoading = false
                        return
                    }
                case .assetReader:
                    decoderPerformedSeek = true
                    decoderSourceStartTime = physicalSeekTime
                    rawStream = assetReaderDecoder.decode(
                        from: seekURL,
                        outputFormat: outputFormat,
                        startingAt: physicalSeekTime
                    )
                }
                let stream = segmented(
                    rawStream,
                    for: song,
                    sourceStartTime: decoderSourceStartTime
                )
                let seekSamplePosition = targetTime * outputFormat.sampleRate
                guard seekSamplePosition.isFinite else {
                    self.isLoading = false
                    self.updateNowPlayingInfo()
                    self.updatePlaybackState()
                    return
                }
                let progressSeekSamples = Int64(seekSamplePosition.rounded(.down))
                let seekSamples = decoderPerformedSeek ? 0 : progressSeekSamples
                var samplesSkipped: Int64 = 0

                // Set sample time offset so currentTime calculation accounts for seek position
                audioEngine.sampleTimeOffset = -progressSeekSamples

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
                    isPlaying = false
                    currentTime = targetTime
                    updateNowPlayingInfo()
                    updatePlaybackState()
                    if shouldStartPlaying {
                        await handleTrackEnd()
                    }
                    return
                }
                guard playID == id else { return }

                audioEngine.scheduleBuffer(firstBuffer)
                hasPreparedLocalPlayback = true
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
                let gate = AsyncBufferGate(
                    maxBufferedDuration: Self.decodedAudioLookahead,
                    maxBufferCount: Self.maxInFlightDecodedBufferCount
                )
                decodingTask = Task { [id, iteratorBox, gate] in
                    var lastBuffer: AVAudioPCMBuffer?
                    defer { Task { await gate.drain() } }

                    do {
                        while let buffer = try await iteratorBox.next() {
                            guard !Task.isCancelled, self.playID == id else { return }

                            if let prev = lastBuffer {
                                let bufferedDuration = Self.decodedBufferDuration(prev)
                                await gate.acquire(duration: bufferedDuration)
                                guard !Task.isCancelled, self.playID == id else { return }
                                self.audioEngine.scheduleBuffer(
                                    prev,
                                    completionCallbackType: .dataConsumed
                                ) { _ in gate.release(duration: bufferedDuration) }
                            }
                            lastBuffer = buffer
                        }
                    } catch {
                        if !Task.isCancelled { plog("Seek decode error: \(error)") }
                    }

                    if let finalBuffer = lastBuffer {
                        guard !Task.isCancelled, self.playID == id else { return }
                        await self.scheduleDecodedFinalBuffer(finalBuffer, playID: id)
                    }
                }
            } catch {
                plog("Seek error: \(error)")
                guard playID == id else { return }
                isLoading = false
                isPlaying = false
                currentTime = previousTime
                showPlaybackError(String(localized: "playback_error_decode"))
                updateNowPlayingInfo()
                updatePlaybackState()
                if shouldStartPlaying {
                    // The seek pipeline has already stopped the node. Restart
                    // predictably from the track beginning instead of leaving
                    // a play icon/progress position that does not match audio.
                    await play(song: song)
                }
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
        guard !songs.isEmpty else {
            plog("🎶 setQueue empty — clearing queue")
            clearQueue()
            return
        }

        invalidateQueueTransitions()
        queueEntries = songs.map { QueueEntry(song: $0) }
        currentIndex = max(0, min(index, songs.count - 1))
        // Protect any newly-installed canonical queue from an existing Apple
        // Music mirror during the short interval before `play(song:)` runs.
        isPrimuseManagingAppleMusicQueue = true
        let currentTitle = queueEntries[currentIndex].song.title
        let firstTitle = queueEntries.first?.song.title ?? "-"
        let lastTitle = queueEntries.last?.song.title ?? "-"
        plog("🎶 setQueue count=\(songs.count) startIndex=\(currentIndex) current='\(currentTitle)' first='\(firstTitle)' last='\(lastTitle)'")
        // Drop any pre-built next round — the queue itself changed, so
        // prior shuffle plans (and their indices into the old queue)
        // are stale and would index out-of-bounds on wrap.
        pendingNextShuffleIndices = nil
        if shuffleEnabled { rebuildShuffleOrder() }
    }

    /// Append songs to the end of the current queue without interrupting the
    /// current track. Used by macOS list-level "add all to queue" actions.
    func appendToQueue(_ songs: [Song]) {
        let playable = songs.filteredPlayable()
        guard !playable.isEmpty else { return }
        invalidateQueueTransitions()
        queueEntries.append(contentsOf: playable.map { QueueEntry(song: $0) })
        if isAppleMusicMode {
            isPrimuseManagingAppleMusicQueue = true
            AppServices.shared.appleMusic.prepareForPrimuseManagedQueue()
        }
        pendingNextShuffleIndices = nil
        if shuffleEnabled { rebuildShuffleOrder() }
    }

    /// Insert songs immediately after the current queue position. If there is
    /// no queue yet, this behaves like `setQueue`.
    func insertNextInQueue(_ songs: [Song]) {
        let playable = songs.filteredPlayable()
        guard !playable.isEmpty else { return }
        guard !queueEntries.isEmpty else {
            setQueue(playable, startAt: 0)
            return
        }
        let insertionIndex = min(currentIndex + 1, queueEntries.count)
        invalidateQueueTransitions()
        queueEntries.insert(contentsOf: playable.map { QueueEntry(song: $0) }, at: insertionIndex)
        if isAppleMusicMode {
            isPrimuseManagingAppleMusicQueue = true
            AppServices.shared.appleMusic.prepareForPrimuseManagedQueue()
        }
        pendingNextShuffleIndices = nil
        if shuffleEnabled { rebuildShuffleOrder() }
    }

    /// 删掉队列前 `count` 首歌, 同时把 `currentIndex` 往前平移 (不让它跑负)。
    /// MacQueuePanel 的 "清掉已播放" 按钮直接调这个 ── 之前是把 player.queue
    /// 当 var 用, 但 queue 现在是 computed。
    func removeQueuePrefix(count: Int) {
        guard count > 0 else { return }
        let toRemove = min(count, queueEntries.count)
        invalidateQueueTransitions()
        queueEntries.removeFirst(toRemove)
        currentIndex = max(0, currentIndex - toRemove)
        pendingNextShuffleIndices = nil
        if shuffleEnabled { rebuildShuffleOrder() }
    }

    /// Wipe the queue. Replaces the legacy `player.queue = []` setter,
    /// which is no longer accessible since `queue` is now computed.
    func clearQueue() {
        invalidateQueueTransitions()
        queueEntries = []
        currentIndex = 0
        pendingNextShuffleIndices = nil
        shuffledIndices = []
        shufflePosition = 0
        isPrimuseManagingAppleMusicQueue = false
    }

    /// Move queue rows. Used by the QueueView reorder handle. Beyond
    /// the obvious `move`, this also invalidates any pending shuffle
    /// plan and rebuilds the shuffle order — `shuffledIndices` stores
    /// raw queue offsets, so a manual reorder makes those offsets
    /// point at the wrong songs unless we regenerate them.
    func moveQueueItems(fromOffsets source: IndexSet, toOffset destination: Int) {
        guard !source.isEmpty,
              source.allSatisfy({ queueEntries.indices.contains($0) }),
              destination >= 0,
              destination <= queueEntries.count else { return }
        invalidateQueueTransitions()
        queueEntries.move(fromOffsets: source, toOffset: destination)
        pendingNextShuffleIndices = nil
        if shuffleEnabled {
            rebuildShuffleOrder()
        }
    }

    /// Play the queue entry at a raw `queueEntries` index, keeping the player's
    /// shuffle bookkeeping in sync. The QueueView taps map to raw queue indices;
    /// in shuffle mode `currentIndex` alone isn't enough — `shufflePosition` /
    /// `shuffledIndices` also have to point at the tapped track or the next
    /// `next()` advances from a stale shuffle position. Unlike toggling
    /// `shuffleEnabled` (which reshuffles the whole round), this only swaps the
    /// tapped index into the current shuffle position, leaving the *rest* of the
    /// round's order untouched so Up Next stays stable.
    func playFromQueue(at index: Int) async {
        guard queueEntries.indices.contains(index) else { return }

        // Apple Music mode owns its own queue/order via the system player —
        // route through `play(song:)` and let the mirror keep state in sync,
        // mirroring how `shuffleEnabled.didSet` short-circuits there.
        if shuffleEnabled, !isAppleMusicMode, !isMirroringFromAppleMusic {
            if let targetPos = shuffledIndices.firstIndex(of: index) {
                // Pull the tapped track into the current shuffle position. The
                // displaced index moves to where the tapped one was, so every
                // other position keeps its relative order (no reshuffle).
                let anchorPos = min(max(shufflePosition, 0), shuffledIndices.count - 1)
                shuffledIndices.swapAt(anchorPos, targetPos)
                shufflePosition = anchorPos
            }
        }

        currentIndex = index
        let song = queueEntries[index].song
        await play(song: song)
    }

    /// Played entries in actual traversal order. Raw queue indices are only a
    /// valid played/current/upcoming partition when shuffle is disabled.
    var playedQueueEntries: [QueuePresentationEntry] {
        let occurrences = QueuePresentationPolicy.playedOccurrences(
            queueCount: queueEntries.count,
            currentIndex: currentIndex,
            shuffledIndices: usesManagedShuffleOrder ? shuffledIndices : nil,
            shufflePosition: shufflePosition
        )
        return presentationEntries(for: occurrences)
    }

    /// Up Next entries in the order they'll actually play. The next repeat-all
    /// shuffle round receives a distinct presentation identity even though it
    /// intentionally references the same durable queue slots.
    var upcomingQueueEntries: [QueuePresentationEntry] {
        var nextRoundIndices: [Int]?
        if usesManagedShuffleOrder, repeatMode == .all {
            nextRoundIndices = preparedNextShuffleRound()
        }
        let occurrences = QueuePresentationPolicy.upcomingOccurrences(
            queueCount: queueEntries.count,
            currentIndex: currentIndex,
            shuffledIndices: usesManagedShuffleOrder ? shuffledIndices : nil,
            shufflePosition: shufflePosition,
            nextRoundIndices: nextRoundIndices
        )
        return presentationEntries(for: occurrences)
    }

    private var usesManagedShuffleOrder: Bool {
        shuffleEnabled && !(isAppleMusicMode && !isPrimuseManagingAppleMusicQueue)
    }

    private func presentationEntries(
        for occurrences: [QueuePresentationOccurrence]
    ) -> [QueuePresentationEntry] {
        occurrences.compactMap { occurrence in
            guard queueEntries.indices.contains(occurrence.queueIndex) else { return nil }
            return QueuePresentationEntry(
                entry: queueEntries[occurrence.queueIndex],
                roundOffset: occurrence.roundOffset
            )
        }
    }

    func syncSongMetadata(_ updatedSong: Song) {
        if currentSong?.id == updatedSong.id {
            currentSong = updatedSong
            let updatedDuration = updatedSong.duration.sanitizedDuration
            if updatedDuration > 0 {
                duration = updatedDuration
            }
            updateNowPlayingInfo()
            updatePlaybackState()
        }
        // Keep the per-row UUID stable — mutate only `song` so SwiftUI
        // doesn't see a row disappear/reappear when metadata backfill
        // rewrites tags mid-listening.
        if let queueIndex = queueEntries.firstIndex(where: { $0.song.id == updatedSong.id }) {
            queueEntries[queueIndex].song = updatedSong
        }
    }

    /// Replace a transient catalog-derived Apple Music identity with the
    /// canonical user-library row without restarting playback. This is used as
    /// a final guard by metadata actions that can be tapped between MusicKit
    /// polling ticks.
    func adoptCanonicalAppleMusicSong(_ canonical: Song, replacing aliasSongID: String) {
        guard canonical.sourceID == AppleMusicLibraryService.systemSourceID,
              currentSong?.sourceID == AppleMusicLibraryService.systemSourceID,
              currentSong?.id == aliasSongID else { return }

        currentSong = canonical
        if canonical.duration > 0 { duration = canonical.duration }
        for index in queueEntries.indices where queueEntries[index].song.id == aliasSongID {
            queueEntries[index].song = canonical
        }
        updateNowPlayingInfo()
        updatePlaybackState()
    }

    // MARK: - Gapless Playback

    private func startGaplessPreparation(playID id: UUID, transition: GaplessTransitionState) {
        gaplessPreparationTask?.cancel()
        gaplessPreparationTask = Task { [id, transition] in
            await self.prepareGaplessNextTrack(playID: id, transition: transition)
        }
    }

    private func handleGaplessBoundary(
        transition: GaplessTransitionState,
        playID id: UUID
    ) async {
        transition.didBoundaryFire = true

        // 防御性兜底: 10 秒内 boundary 触发 ≥4 次 = 队列里有 partial/坏掉
        // 的歌反复切歌, 强制 pause 并 cancel 后续准备, 避免占满
        // CPU + 不停下载 + UI 像是 loading 卡死的体感。
        let now = Date()
        recentBoundaryTimes.append(now)
        recentBoundaryTimes.removeAll { now.timeIntervalSince($0) > Self.boundaryStormWindow }
        if recentBoundaryTimes.count >= Self.boundaryStormThreshold {
            plog("⚠️ gapless boundary storm: \(recentBoundaryTimes.count) 次 / \(Int(Self.boundaryStormWindow))s — 暂停播放, 队列里可能有不完整的缓存文件")
            recentBoundaryTimes.removeAll()
            transition.shouldCancelPreparation = true
            cancelGaplessTasks()
            pause()
            return
        }

        // Sanity check: 当前歌还远没听完就 fire boundary, 说明上游有问题
        // (CloudPlaybackSource 短读 / decoder 误判 EOF / MP3 帧元数据偏差),
        // 直接切歌会让用户体感是"歌没播完就跳了"。这里重建当前歌曲的
        // decoder pipeline, 从当前进度前一点继续拉数据; 如果仍失败,
        // seek 路径会停在当前曲而不是静默跳到下一首。
        if duration > 30, currentTime < duration - 5, !isLoading {
            plog("⚠️ premature gapless boundary suppressed: currentTime=\(String(format: "%.1f", currentTime))s duration=\(String(format: "%.1f", duration))s playID=\(id.uuidString.prefix(8))")
            transition.shouldCancelPreparation = true
            cancelGaplessTasks()
            showPlaybackError(String(localized: "playback_error_connection"))
            let recoveryTime = max(0, currentTime - 2)
            seek(to: recoveryTime, startPlaying: true, isRecovery: true)
            return
        }

        let settings = playbackSettings.snapshot()

        // The user can switch Crossfade on after the gapless final buffer
        // has already been scheduled. In that race, the crossfade path owns
        // the transition and will swap nodes; do not also advance here.
        if shouldUseCrossfade(settings), crossfadeTriggered {
            transition.shouldCancelPreparation = true
            gaplessPreparationTask?.cancel()
            gaplessPreparationTask = nil
            return
        }

        if let lockedID = sleepStopAfterSongID, currentSong?.id == lockedID {
            sleepStopAfterSongID = nil
            transition.shouldCancelPreparation = true
            cancelGaplessTasks()
            stopAtTrackEnd()
            return
        }

        guard shouldAttemptGapless(settings: settings),
              queueGeneration == transition.queueGeneration,
              let prepared = transition.prepared,
              nextSongInQueue()?.id == prepared.song.id else {
            transition.shouldCancelPreparation = true
            gaplessPreparationTask?.cancel()
            gaplessPreparationTask = nil
            await handleTrackEnd()
            return
        }

        activateGaplessTrack(prepared, completedTransition: transition, playID: id)
    }

    private func activateGaplessTrack(
        _ prepared: GaplessPreparedTrack,
        completedTransition: GaplessTransitionState,
        playID id: UUID
    ) {
        guard playID == id else { return }

        if let previous = currentSong {
            sourceManager?.finalizeStreamingSession(for: previous)
        }

        audioEngine.markTrackBoundary()
        advanceToNextIndex()
        currentSong = prepared.song
        duration = prepared.song.duration.sanitizedDuration
        currentTime = 0
        isLoading = false
        isPlaying = true
        isAtTrackEnd = false
        crossfadeTriggered = false
        isCrossfading = false
        activeDecoderKind = prepared.decoderKind
        library?.recordPlayback(of: prepared.song.id)
        ScrobbleService.shared.handlePlaybackStarted(song: prepared.song)
        PlayHistoryStore.shared.beginSession(song: prepared.song)

        let settings = playbackSettings.snapshot()
        if shouldApplyReplayGain(settings) {
            Task { [id] in
                await self.applyReplayGain(
                    for: prepared.song,
                    url: prepared.url,
                    mode: settings.replayGainMode,
                    allowFileRead: prepared.decoderKind != .cloudStream && prepared.decoderKind != .httpStream,
                    expectedPlayID: id,
                    expectedSongID: prepared.song.id
                )
            }
        } else {
            audioEngine.resetPlayerVolume()
        }

        if duration <= 0,
           !prepared.song.isCueTrack,
           prepared.decoderKind != .cloudStream,
           prepared.decoderKind != .httpStream {
            Task { [id] in
                let decoder: any PrimuseAudioDecoder = prepared.decoderKind == .ffmpeg
                    ? self.ffmpegDecoder : self.nativeDecoder
                if let info = try? await decoder.fileInfo(for: prepared.url) {
                    guard self.playID == id, self.currentSong?.id == prepared.song.id else { return }
                    self.duration = info.duration.sanitizedDuration
                    self.updateNowPlayingInfo()
                }
            }
        }

        startTimeUpdater()
        updateNowPlayingInfo()
        updateNowPlayingArtworkIfNeeded()
        updatePlaybackState()
        prefetchNextSong()
        startGaplessFollowupPreparation(
            playID: id,
            after: completedTransition,
            followingTransition: prepared.followingTransition
        )
    }

    private func startGaplessFollowupPreparation(
        playID id: UUID,
        after completedTransition: GaplessTransitionState,
        followingTransition: GaplessTransitionState
    ) {
        gaplessFollowupTask?.cancel()
        gaplessFollowupTask = Task { [id, completedTransition, followingTransition] in
            while !Task.isCancelled {
                guard self.playID == id,
                      self.queueGeneration == completedTransition.queueGeneration,
                      !completedTransition.shouldCancelPreparation,
                      !completedTransition.didFail else { return }
                if completedTransition.isFullyScheduled { break }
                try? await Task.sleep(for: .milliseconds(100))
            }

            guard !Task.isCancelled,
                  self.playID == id,
                  self.queueGeneration == followingTransition.queueGeneration else { return }
            self.startGaplessPreparation(playID: id, transition: followingTransition)
        }
    }

    private func prepareGaplessNextTrack(
        playID id: UUID,
        transition: GaplessTransitionState
    ) async {
        guard playID == id,
              queueGeneration == transition.queueGeneration,
              !transition.shouldCancelPreparation,
              shouldAttemptGapless(settings: playbackSettings.snapshot()),
              let nextSong = nextSongInQueue() else { return }

        var nextURL: URL
        var nextDecoderKind: DecoderKind
        do {
            nextURL = try await resolvedURL(for: nextSong)
            nextDecoderKind = await decoderKind(for: nextSong, url: nextURL)
        } catch {
            plog("Gapless prepare URL error: \(error.localizedDescription)")
            return
        }

        guard playID == id,
              queueGeneration == transition.queueGeneration,
              !transition.shouldCancelPreparation,
              nextDecoderKind == .native || nextDecoderKind == .ffmpeg || nextDecoderKind == .httpStream || nextDecoderKind == .cloudStream,
              nextDecoderKind != .native || nativeDecoder.canDecode(url: nextURL),
              let outputFormat = audioEngine.outputFormat else { return }

        guard let stream = await decodeStream(for: nextSong, url: nextURL, outputFormat: outputFormat) else {
            return
        }

        let followingTransition = GaplessTransitionState(queueGeneration: queueGeneration)
        var lastBuffer: AVAudioPCMBuffer?
        var didMarkPrepared = false
        // Pace the next track's buffers to consumption of the *current* track's
        // buffers (same player node) so a fully prepared gapless track doesn't
        // double the resident PCM alongside the song that's still playing.
        let gate = AsyncBufferGate(
            maxBufferedDuration: Self.decodedAudioLookahead,
            maxBufferCount: Self.maxInFlightDecodedBufferCount
        )
        defer { Task { await gate.drain() } }

        func markPreparedIfNeeded() {
            guard !didMarkPrepared else { return }
            didMarkPrepared = true
            transition.prepared = GaplessPreparedTrack(
                song: nextSong,
                url: nextURL,
                decoderKind: nextDecoderKind,
                followingTransition: followingTransition
            )
            plog("🔄 gapless prepared next track '\(nextSong.title)'")
        }

        do {
            for try await buffer in stream {
                guard !Task.isCancelled,
                      playID == id,
                      queueGeneration == transition.queueGeneration,
                      !transition.shouldCancelPreparation else { return }

                if let prev = lastBuffer {
                    let bufferedDuration = Self.decodedBufferDuration(prev)
                    await gate.acquire(duration: bufferedDuration)
                    guard !Task.isCancelled,
                          playID == id,
                          queueGeneration == transition.queueGeneration,
                          !transition.shouldCancelPreparation else { return }
                    audioEngine.scheduleBuffer(
                        prev,
                        completionCallbackType: .dataConsumed
                    ) { _ in gate.release(duration: bufferedDuration) }
                    markPreparedIfNeeded()
                }
                lastBuffer = buffer
            }
        } catch {
            guard !Task.isCancelled,
                  playID == id,
                  queueGeneration == transition.queueGeneration,
                  !transition.shouldCancelPreparation else { return }
            transition.didFail = true
            plog("Gapless prepare decode error: \(error.localizedDescription)")
            if let tailBuffer = lastBuffer {
                audioEngine.scheduleBuffer(
                    tailBuffer,
                    completionCallbackType: .dataPlayedBack
                ) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        guard let self, self.playID == id else { return }
                        await self.autoAdvanceAfterFailure()
                    }
                }
                markPreparedIfNeeded()
                transition.isFullyScheduled = true
            }
            return
        }

        guard !Task.isCancelled,
              playID == id,
              queueGeneration == transition.queueGeneration,
              !transition.shouldCancelPreparation,
              let finalBuffer = lastBuffer else { return }

        audioEngine.scheduleBuffer(
            finalBuffer,
            completionCallbackType: .dataPlayedBack
        ) { [weak self, followingTransition] _ in
            Task { @MainActor [weak self] in
                guard let self, self.playID == id else { return }
                plog("🔔 gapless boundary fired (prepared) playID=\(id.uuidString.prefix(8))")
                await self.handleGaplessBoundary(transition: followingTransition, playID: id)
            }
        }
        markPreparedIfNeeded()
        transition.isFullyScheduled = true
    }

    // MARK: - Crossfade

    private func isCurrentCrossfadeAttempt(
        _ attemptID: UUID,
        sourcePlayID: UUID,
        queueGeneration sourceQueueGeneration: Int,
        nextEntryID: UUID
    ) -> Bool {
        !Task.isCancelled
            && isPlaying
            && crossfadeAttemptID == attemptID
            && playID == sourcePlayID
            && queueGeneration == sourceQueueGeneration
            && nextQueueEntryInQueue()?.id == nextEntryID
    }

    private func failCrossfadeAttempt(_ attemptID: UUID) {
        guard crossfadeAttemptID == attemptID else { return }
        let hadAudibleTransition = isCrossfading || crossfadeTimer != nil
        crossfadeAttemptID = nil
        committedCrossfade = nil
        crossfadeStartupTask = nil
        crossfadeTimer?.invalidate()
        crossfadeTimer = nil
        crossfadeTimerAttemptID = nil
        crossfadeTriggered = false
        isCrossfading = false
        crossfadeSwapDone = false
        if hadAudibleTransition {
            audioEngine.stopCrossfadeNode()
            audioEngine.resetPlayerVolume()
        }
    }

    /// Invalidates both the not-yet-ready startup and any active fade/feeder.
    /// Every queue or playback ownership change goes through this helper so an
    /// old task cannot mutate a newer attempt's flags or queue index.
    private func cancelCrossfadeAttempt(finishingCommittedTransition: Bool = false) {
        if finishingCommittedTransition,
           let committedCrossfade,
           crossfadeAttemptID == committedCrossfade.attemptID,
           playID == committedCrossfade.playID {
            crossfadeTimer?.invalidate()
            crossfadeTimer = nil
            crossfadeTimerAttemptID = nil
            completeCrossfade(
                attemptID: committedCrossfade.attemptID,
                playID: committedCrossfade.playID,
                nextSong: committedCrossfade.song,
                nextURL: committedCrossfade.url,
                nextDecoderKind: committedCrossfade.decoderKind
            )
            return
        }
        let hadActiveAttempt = crossfadeAttemptID != nil
            || crossfadeStartupTask != nil
            || crossfadeDecodingTask != nil
            || crossfadeTimer != nil
            || crossfadeTriggered
            || isCrossfading
        crossfadeAttemptID = nil
        committedCrossfade = nil
        crossfadeStartupTask?.cancel()
        crossfadeStartupTask = nil
        crossfadeDecodingTask?.cancel()
        crossfadeDecodingTask = nil
        crossfadeTimer?.invalidate()
        crossfadeTimer = nil
        crossfadeTimerAttemptID = nil
        crossfadeTriggered = false
        isCrossfading = false
        crossfadeSwapDone = false
        if hadActiveAttempt {
            audioEngine.stopCrossfadeNode()
            audioEngine.resetPlayerVolume()
        }
    }

    private func invalidateQueueTransitions() {
        queueGeneration += 1
        cancelGaplessTasks()
        cancelCrossfadeAttempt(finishingCommittedTransition: true)
    }

    private func checkCrossfade() {
        // This runs on every playback progress tick. Avoid copying the full
        // settings payload in the overwhelmingly common disabled case.
        guard playbackSettings.outputMode == .effects,
              playbackSettings.crossfadeEnabled,
              !crossfadeTriggered else { return }
        let settings = playbackSettings.snapshot()
        guard duration > 0, currentTime >= duration - settings.crossfadeDuration else { return }
        // "Stop after this song" owns the upcoming boundary. Let the normal
        // end callback stop playback instead of committing the next queue item.
        if let lockedID = sleepStopAfterSongID, currentSong?.id == lockedID {
            return
        }
        // Skip under repeat-one — `nextSongInQueue()` returns the
        // current song there, which would crossfade-to-self. Pre-fix
        // `currentIndex < queue.count - 1` was always false in the
        // single-song repeat-one case so crossfade was never enabled;
        // preserve that.
        guard repeatMode != .one,
              let sourcePlayID = playID,
              let nextEntry = nextQueueEntryInQueue() else { return }
        let nextSong = nextEntry.song
        guard shouldBypassContinuousAudioTransition(for: nextSong) == false else { return }

        let attemptID = UUID()
        let sourceQueueGeneration = queueGeneration
        crossfadeAttemptID = attemptID
        crossfadeTriggered = true
        crossfadeStartupTask?.cancel()
        crossfadeStartupTask = Task {
            await startCrossfade(
                duration: settings.crossfadeDuration,
                attemptID: attemptID,
                sourcePlayID: sourcePlayID,
                queueGeneration: sourceQueueGeneration,
                nextEntryID: nextEntry.id
            )
        }
    }

    private func startCrossfade(
        duration crossfadeDuration: Double,
        attemptID: UUID,
        sourcePlayID: UUID,
        queueGeneration sourceQueueGeneration: Int,
        nextEntryID: UUID
    ) async {
        guard isCurrentCrossfadeAttempt(
            attemptID,
            sourcePlayID: sourcePlayID,
            queueGeneration: sourceQueueGeneration,
            nextEntryID: nextEntryID
        ) else { return }
        guard shouldUseCrossfade(playbackSettings.snapshot()) else {
            failCrossfadeAttempt(attemptID)
            return
        }
        guard let nextEntry = nextQueueEntryInQueue(), nextEntry.id == nextEntryID else {
            failCrossfadeAttempt(attemptID)
            return
        }
        let nextSong = nextEntry.song
        guard shouldBypassContinuousAudioTransition(for: nextSong) == false else {
            failCrossfadeAttempt(attemptID)
            return
        }

        let preparationDeadline = Date().addingTimeInterval(Double(Self.firstBufferTimeoutSeconds))
        do {
            let nextURL = try await resolvedURL(for: nextSong)
            let nextDecoderKind = await decoderKind(for: nextSong, url: nextURL)
            guard isCurrentCrossfadeAttempt(
                attemptID,
                sourcePlayID: sourcePlayID,
                queueGeneration: sourceQueueGeneration,
                nextEntryID: nextEntryID
            ) else { return }
            guard nextDecoderKind == .native
                    || nextDecoderKind == .ffmpeg
                    || nextDecoderKind == .httpStream
                    || nextDecoderKind == .cloudStream,
                  nextDecoderKind != .native
                    || nativeDecoder.canDecode(url: nextURL),
                  let outputFormat = audioEngine.outputFormat else {
                failCrossfadeAttempt(attemptID)
                return
            }

            // crossfade 一开始就把 UI 切到下一首 —— 用户听到的主音是 next
            // 在淡入接管, 看到的应该跟着是 next。之前要等 ramp 跑完才切,
            // 出现「下一首歌的声音出来了但播放器还显示上一首」的不一致。
            // 在拿到下一首缓冲 *之前* 不冻结进度、不推进队列索引/
            // currentSong/scrobble —— 否则网络预取慢或 decode 失败时会抑制
            // 曲末 watchdog，并出现
            // 「UI 已切到下一首、声音还停在上一首、isCrossfading 卡 true 进度永久冻结」。

            // Note: ReplayGain for crossfade node would need per-node volume tracking
            // For now, apply after swap

            // Decode into crossfade node — 先确保能解码并拿到首个 buffer。
            guard let stream = await decodeStream(for: nextSong, url: nextURL, outputFormat: outputFormat) else {
                failCrossfadeAttempt(attemptID)
                return
            }
            let iteratorBox = BufferIteratorBox(stream.makeAsyncIterator())

            // swap 还没发生 —— 新曲的 buffer 先进 crossfade 节点。
            crossfadeSwapDone = false
            let firstBufferSeconds = Int(ceil(preparationDeadline.timeIntervalSinceNow))
            guard firstBufferSeconds > 0 else {
                failCrossfadeAttempt(attemptID)
                return
            }
            guard let firstBuffer = try await awaitFirstBuffer(
                from: iteratorBox,
                timeoutSeconds: firstBufferSeconds
            ) else {
                failCrossfadeAttempt(attemptID)
                return
            }
            guard isCurrentCrossfadeAttempt(
                attemptID,
                sourcePlayID: sourcePlayID,
                queueGeneration: sourceQueueGeneration,
                nextEntryID: nextEntryID
            ) else { return }
            // Hold one decoded buffer back so EOF is known before scheduling
            // the physical last buffer. This gives unknown-duration cloud
            // tracks a reliable `.dataPlayedBack` boundary instead of relying
            // on the duration watchdog.
            let remainingBufferSeconds = Int(ceil(preparationDeadline.timeIntervalSinceNow))
            guard remainingBufferSeconds > 0 else {
                failCrossfadeAttempt(attemptID)
                return
            }
            let secondBuffer = try await awaitFirstBuffer(
                from: iteratorBox,
                timeoutSeconds: remainingBufferSeconds
            )
            guard isCurrentCrossfadeAttempt(
                attemptID,
                sourcePlayID: sourcePlayID,
                queueGeneration: sourceQueueGeneration,
                nextEntryID: nextEntryID
            ) else { return }
            // Settings and the sleep lock can change while remote resolution
            // or prefetch is in flight. Revalidate at the commit boundary.
            guard shouldUseCrossfade(playbackSettings.snapshot()),
                  sleepStopAfterSongID != currentSong?.id else {
                failCrossfadeAttempt(attemptID)
                return
            }
            isCrossfading = true
            let nextPlayID = UUID()
            committedCrossfade = CommittedCrossfade(
                attemptID: attemptID,
                playID: nextPlayID,
                song: nextSong,
                url: nextURL,
                decoderKind: nextDecoderKind
            )
            playID = nextPlayID

            // 解码就绪, 现在才把 UI/索引/scrobble 切到下一首 —— 用户听到 next
            // 淡入接管, 看到的也跟着切。
            if let previous = currentSong {
                sourceManager?.finalizeStreamingSession(for: previous)
            }
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

            if secondBuffer == nil {
                scheduleCrossfadeFinalBuffer(firstBuffer, playID: nextPlayID)
            } else {
                audioEngine.scheduleCrossfadeBuffer(firstBuffer)
            }
            audioEngine.playCrossfadeNode()

            let gate = AsyncBufferGate(
                maxBufferedDuration: Self.decodedAudioLookahead,
                maxBufferCount: Self.maxInFlightDecodedBufferCount
            )
            crossfadeStartupTask = nil
            crossfadeDecodingTask = Task { [iteratorBox, gate] in
                var lastBuffer = secondBuffer
                var decodeFailed = false
                defer { Task { await gate.drain() } }
                do {
                    while let buffer = try await iteratorBox.next() {
                        guard !Task.isCancelled else { return }
                        if let previous = lastBuffer {
                            let bufferedDuration = Self.decodedBufferDuration(previous)
                            await gate.acquire(duration: bufferedDuration)
                            guard !Task.isCancelled, self.playID == nextPlayID else { return }
                            // swap 之后, 这个解码任务投递的物理节点已经变成
                            // primary。继续用 scheduleCrossfadeBuffer 会把 buffer
                            // 喂到换出后被静音/reset 的旧节点上(歌中途静音)。
                            if self.crossfadeSwapDone {
                                self.audioEngine.scheduleBuffer(
                                    previous,
                                    completionCallbackType: .dataConsumed
                                ) { _ in gate.release(duration: bufferedDuration) }
                            } else {
                                self.audioEngine.scheduleCrossfadeBuffer(
                                    previous,
                                    completionCallbackType: .dataConsumed
                                ) { _ in gate.release(duration: bufferedDuration) }
                            }
                        }
                        lastBuffer = buffer
                    }
                } catch {
                    if !Task.isCancelled {
                        decodeFailed = true
                        plog("Crossfade decode error: \(error)")
                    }
                }
                if let finalBuffer = lastBuffer {
                    guard !Task.isCancelled, self.playID == nextPlayID else { return }
                    if decodeFailed {
                        self.scheduleCrossfadeFinalBufferAsFailure(finalBuffer, playID: nextPlayID)
                    } else {
                        self.scheduleCrossfadeFinalBuffer(finalBuffer, playID: nextPlayID)
                    }
                } else if decodeFailed, !Task.isCancelled, self.playID == nextPlayID {
                    await self.autoAdvanceAfterFailure()
                }
            }

            startCrossfadeRamp(
                duration: crossfadeDuration,
                attemptID: attemptID,
                playID: nextPlayID,
                nextSong: nextSong,
                nextURL: nextURL,
                nextDecoderKind: nextDecoderKind
            )
        } catch {
            guard crossfadeAttemptID == attemptID else { return }
            plog("Crossfade start error: \(error)")
            failCrossfadeAttempt(attemptID)
        }
    }

    private func startCrossfadeRamp(
        duration: Double,
        attemptID: UUID,
        playID rampPlayID: UUID,
        nextSong: Song,
        nextURL: URL,
        nextDecoderKind: DecoderKind
    ) {
        guard crossfadeAttemptID == attemptID,
              playID == rampPlayID,
              committedCrossfade?.attemptID == attemptID else { return }
        let totalSteps = max(1, (duration / 0.05).finiteInt(or: 1))
        let stepCounter = StepCounter()
        crossfadeTimerAttemptID = attemptID
        crossfadeTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self,
                      self.crossfadeAttemptID == attemptID,
                      self.playID == rampPlayID else {
                    if self?.crossfadeTimerAttemptID == attemptID {
                        self?.crossfadeTimer?.invalidate()
                        self?.crossfadeTimer = nil
                        self?.crossfadeTimerAttemptID = nil
                    }
                    return
                }
                // AudioEngine pauses both physical nodes. Freeze the ramp too;
                // otherwise a user pause completes the swap in silence.
                guard self.isPlaying else { return }
                stepCounter.value += 1
                let progress = Float(stepCounter.value) / Float(totalSteps)

                if progress >= 1.0 {
                    if self.crossfadeTimerAttemptID == attemptID {
                        self.crossfadeTimer?.invalidate()
                        self.crossfadeTimer = nil
                        self.crossfadeTimerAttemptID = nil
                    }
                    self.completeCrossfade(
                        attemptID: attemptID,
                        playID: rampPlayID,
                        nextSong: nextSong,
                        nextURL: nextURL,
                        nextDecoderKind: nextDecoderKind
                    )
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

    private func completeCrossfade(
        attemptID: UUID,
        playID completedPlayID: UUID,
        nextSong: Song,
        nextURL: URL,
        nextDecoderKind: DecoderKind
    ) {
        guard crossfadeAttemptID == attemptID, playID == completedPlayID else { return }
        // Stop old decoding
        decodingTask?.cancel()
        decodingTask = nil

        // swap 把 crossfade 节点变成 primary。先置位, 让仍在运行的 crossfade
        // 解码任务从下一个 buffer 起改投 primary 节点, 不再喂换出的旧节点。
        crossfadeSwapDone = true

        // Swap nodes
        audioEngine.swapPlayerNodes()
        audioEngine.sampleTimeOffset = 0

        // Transfer crossfade decoding task to main
        decodingTask = crossfadeDecodingTask
        crossfadeDecodingTask = nil

        // 注意: currentSong / queue index / scrobble session 已经在
        // startCrossfade 早期设置好了, 不在这里重复 (重复会让 ScrobbleService
        // 误以为又开了一首新歌, 重新计时)。
        activeDecoderKind = nextDecoderKind
        crossfadeAttemptID = nil
        committedCrossfade = nil
        crossfadeStartupTask = nil
        crossfadeTriggered = false; isCrossfading = false
        isCrossfading = false
        plog("🔄 completeCrossfade: swap done, currentSong=\(nextSong.title)")

        // Apply ReplayGain (now on the swapped primary node)
        let settings = playbackSettings.snapshot()
        if shouldApplyReplayGain(settings) {
            Task {
                await applyReplayGain(
                    for: nextSong,
                    url: nextURL,
                    mode: settings.replayGainMode,
                    allowFileRead: nextDecoderKind != .cloudStream && nextDecoderKind != .httpStream,
                    expectedPlayID: completedPlayID,
                    expectedSongID: nextSong.id
                )
            }
        }

        if !nextSong.isCueTrack,
           nextDecoderKind != .cloudStream,
           nextDecoderKind != .httpStream,
           nextDecoderKind != .streaming {
            Task {
                let decoder: any PrimuseAudioDecoder = nextDecoderKind == .ffmpeg
                    ? self.ffmpegDecoder : self.nativeDecoder
                if let info = try? await decoder.fileInfo(for: nextURL) {
                    guard self.playID == completedPlayID,
                          self.currentSong?.id == nextSong.id,
                          info.duration.isFinite,
                          info.duration > 0 else { return }
                    self.duration = info.duration
                }
            }
        }

        updateNowPlayingInfo()
        updatePlaybackState()
    }

    // MARK: - ReplayGain

    private struct ReplayGainValues {
        var gain: Double?
        var peak: Double?

        var hasValue: Bool {
            gain != nil || peak != nil
        }
    }

    private func applyReplayGain(
        for song: Song,
        url: URL,
        mode: ReplayGainMode,
        allowFileRead: Bool = true,
        expectedPlayID: UUID? = nil,
        expectedSongID: String? = nil
    ) async {
        guard expectedPlayID == nil || playID == expectedPlayID,
              expectedSongID == nil || currentSong?.id == expectedSongID else { return }
        let storedValues = replayGainValues(from: song, mode: mode)
        if storedValues.hasValue {
            audioEngine.applyReplayGain(gain: storedValues.gain, peak: storedValues.peak)
            return
        }

        guard allowFileRead else {
            audioEngine.applyReplayGain(gain: nil, peak: nil)
            return
        }

        let metadata = await FileMetadataReader.read(from: url)
        guard expectedPlayID == nil || playID == expectedPlayID,
              expectedSongID == nil || currentSong?.id == expectedSongID else { return }
        let values = replayGainValues(from: metadata, mode: mode)
        audioEngine.applyReplayGain(gain: values.gain, peak: values.peak)
    }

    private func replayGainValues(from song: Song, mode: ReplayGainMode) -> ReplayGainValues {
        switch mode {
        case .track:
            return ReplayGainValues(
                gain: song.replayGainTrackGain,
                peak: song.replayGainTrackPeak
            )
        case .album:
            return ReplayGainValues(
                gain: song.replayGainAlbumGain ?? song.replayGainTrackGain,
                peak: song.replayGainAlbumPeak ?? song.replayGainTrackPeak
            )
        }
    }

    private func replayGainValues(from metadata: FileMetadataReader.Metadata, mode: ReplayGainMode) -> ReplayGainValues {
        switch mode {
        case .track:
            return ReplayGainValues(
                gain: metadata.replayGainTrackGain,
                peak: metadata.replayGainTrackPeak
            )
        case .album:
            return ReplayGainValues(
                gain: metadata.replayGainAlbumGain ?? metadata.replayGainTrackGain,
                peak: metadata.replayGainAlbumPeak ?? metadata.replayGainTrackPeak
            )
        }
    }

    // MARK: - Time Updates

    /// 进度 timer 间隔 (秒)。同时作为 scrobble 的真实收听增量 —— 见下方 handleProgressTick。
    private static let timeUpdateInterval: TimeInterval = 0.5

    private func startTimeUpdater() {
        stopTimeUpdater()
        lastEngineProgressSample = nil
        nearEndStallSampleCount = 0
        displayLink = Timer.scheduledTimer(withTimeInterval: Self.timeUpdateInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // crossfade 期间 audioEngine 报的还是旧曲 primary node 时间,
                // 但 UI 已经切到新曲, 直接刷会让进度条乱跳。等 swap 完成
                // (isCrossfading=false) 再继续。
                if self.isCrossfading { return }
                if let time = self.audioEngine.currentTime {
                    self.currentTime = time.sanitizedDuration
                    let madeProgress = self.lastEngineProgressSample.map {
                        self.currentTime > $0 + 0.01
                    } ?? true
                    self.lastEngineProgressSample = self.currentTime

                    // AVAudioPlayerNode normally calls the final-buffer
                    // completion, but it can be lost across route/engine
                    // changes. The old `duration + 1s` check never fired when
                    // the node drained exactly at duration. Detect four
                    // consecutive stalled samples in the final 0.75s instead.
                    let nearEndThreshold = max(
                        self.duration - 0.75,
                        self.duration * 0.98
                    )
                    if self.duration > 0,
                       self.currentTime >= nearEndThreshold,
                       !self.isLoading,
                       self.isPlaying,
                       !madeProgress {
                        self.nearEndStallSampleCount += 1
                    } else {
                        self.nearEndStallSampleCount = 0
                    }
                    let exceededReportedEnd = self.duration > 0
                        && self.currentTime >= self.duration + 1.0
                    if exceededReportedEnd
                        || self.nearEndStallSampleCount >= Self.trackEndStallSampleThreshold {
                        plog("⚠️ Track-end watchdog: progress ended at \(self.currentTime)/\(self.duration), forcing queue advance")
                        self.stopTimeUpdater()
                        await self.handleTrackEnd()
                        return
                    }

                    // Scrobble 进度判断 — 50% 或 4 分钟阈值由 service 内部决定。
                    // 传真实 tick 增量而非 currentTime: 否则用户拖进度条到歌曲后段
                    // 一松手就立刻满足 50% 阈值, 一秒没真听就误上报到 Last.fm/Navidrome。
                    // PlayHistoryStore.tick 维护的是 position high-water mark, 仍传 currentTime。
                    ScrobbleService.shared.handleProgressTick(playedDelta: Self.timeUpdateInterval); PlayHistoryStore.shared.tick(elapsed: self.currentTime)
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
        // 曲终停止 sleep 模式 ── 锁定的歌刚播完, 暂停而不是 advance。
        if let lockedID = sleepStopAfterSongID, currentSong?.id == lockedID {
            sleepStopAfterSongID = nil
            stopAtTrackEnd()  // 进 "已播完但保留 currentSong" 状态, 跟用户手动暂停一致
            return
        }
        if shuffleEnabled, repeatMode != .one, nextSongInQueue() == nil {
            _ = extendExhaustedShuffleFromLibrary()
        }
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
    private func autoAdvanceAfterFailure(skippingSourceID failedSourceID: String? = nil) async {
        if isDLNACast(currentSong) {
            stop()
            return
        }
        if repeatMode == .one {
            stop()
            return
        }

        let startsChain = !isFailureAdvanceChainActive
        if startsChain {
            isFailureAdvanceChainActive = true
            consecutiveFailureAdvanceCount = 0
        }
        defer {
            if startsChain {
                isFailureAdvanceChainActive = false
                consecutiveFailureAdvanceCount = 0
            }
        }

        consecutiveFailureAdvanceCount += 1
        guard consecutiveFailureAdvanceCount <= Self.maxConsecutiveFailureAdvances else {
            plog("⏹️ Stopped after \(Self.maxConsecutiveFailureAdvances) consecutive playback failures")
            stop()
            return
        }

        if let failedSourceID {
            var skippedCount = 0
            while let candidate = nextSongInQueue(),
                  SourceFailureAdvancePolicy.shouldSkipCandidate(
                    failedSourceID: failedSourceID,
                    candidateSourceID: candidate.sourceID
                  ) {
                guard skippedCount < queue.count else {
                    plog("⏹️ No playable provider remains after source-wide failure")
                    stop()
                    return
                }
                advanceToNextIndex()
                skippedCount += 1
            }
            if skippedCount > 0 {
                plog("⏭️ Skipped \(skippedCount) queued entr\(skippedCount == 1 ? "y" : "ies") from unavailable source")
            }
        }

        if nextSongInQueue() != nil {
            await Task.yield()
            await next()
        } else {
            stop()
        }
    }

    /// Authentication, connection and timeout failures normally affect every
    /// track from the same remote source. The failure path skips queued entries
    /// from that source before continuing with the next available provider.
    private func isSourceWideResolutionFailure(_ error: Error) -> Bool {
        if let sourceError = error as? SourceError {
            switch sourceError {
            case .authenticationFailed, .credentialUnavailable,
                 .connectionFailed, .timeout:
                return true
            case .pathNotFound, .fileNotFound:
                return false
            }
        }
        let nsError = error as NSError
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            return isSourceWideResolutionFailure(underlying)
        }
        return false
    }

    private func isDLNACast(_ song: Song?) -> Bool {
        song?.sourceID == Self.dlnaSourceID
    }

    /// Shuffle is a library-discovery mode, not a request to repeat the only
    /// item in a one-song queue. Once the current shuffle round is exhausted,
    /// append currently visible playable songs that are not already present
    /// and make only those new entries the next shuffle segment.
    @discardableResult
    private func extendExhaustedShuffleFromLibrary() -> Bool {
        guard shuffleEnabled,
              repeatMode != .one,
              nextSongInQueue() == nil,
              let library,
              queueEntries.indices.contains(currentIndex) else { return false }

        let playable = library.visibleSongs.filteredPlayable()
        let candidateIDs = ShuffleContinuationPolicy.candidateIDs(
            queueIDs: queueEntries.map(\.song.id),
            libraryIDs: playable.map(\.id),
            currentID: currentSong?.id
        )
        guard !candidateIDs.isEmpty else { return false }

        let songsByID = Dictionary(
            playable.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let additions = candidateIDs.compactMap { songsByID[$0] }
        guard !additions.isEmpty else { return false }

        let firstNewIndex = queueEntries.count
        invalidateQueueTransitions()
        queueEntries.append(contentsOf: additions.map { QueueEntry(song: $0) })
        pendingNextShuffleIndices = nil
        shuffledIndices = [currentIndex]
            + Array(firstNewIndex..<queueEntries.count).shuffled()
        shufflePosition = 0
        plog("🔀 Extended exhausted shuffle queue by \(additions.count) library songs")
        return true
    }

    private func nextQueueEntryInQueue() -> QueueEntry? {
        guard !queueEntries.isEmpty else { return nil }

        if repeatMode == .one {
            guard queueEntries.indices.contains(currentIndex) else { return nil }
            return queueEntries[currentIndex]
        }

        if shuffleEnabled {
            let nextPos = shufflePosition + 1
            if nextPos < shuffledIndices.count {
                let index = shuffledIndices[nextPos]
                return queueEntries.indices.contains(index) ? queueEntries[index] : nil
            } else if repeatMode == .all {
                // Wrap: read the pre-generated next round (lazily built
                // here so the prefetch path and the real advance path
                // pick the SAME song — without this they'd disagree
                // because `advanceToNextIndex` reshuffles fresh and
                // we'd prewarm a completely different track).
                let pending = preparedNextShuffleRound()
                guard let firstIndex = pending.first else { return queueEntries.first }
                return queueEntries.indices.contains(firstIndex) ? queueEntries[firstIndex] : nil
            } else {
                return nil
            }
        }

        let nextIndex = currentIndex + 1
        if queueEntries.indices.contains(nextIndex) {
            return queueEntries[nextIndex]
        } else if repeatMode == .all {
            return queueEntries.first
        }
        return nil
    }

    private func nextSongInQueue() -> Song? {
        nextQueueEntryInQueue()?.song
    }

    private func advanceToNextIndex() {
        guard !queueEntries.isEmpty else { return }
        if shuffleEnabled {
            let nextPos = shufflePosition + 1
            if nextPos < shuffledIndices.count {
                shufflePosition = nextPos
                currentIndex = shuffledIndices[shufflePosition]
            } else {
                // End of round. Adopt the pre-generated next round
                // (built earlier by `nextSongInQueue` for prefetch) so
                // the actual track played matches what was prewarmed.
                let pending = preparedNextShuffleRound()
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

    /// Cache the first generated repeat-all round. `pendingNextShuffleIndices`
    /// is observation-ignored because SwiftUI may call this from a computed
    /// presentation getter; preparing hidden playback state must not invalidate
    /// that getter and start another observation pass.
    private func preparedNextShuffleRound() -> [Int] {
        let prepared = ShuffleRoundPreparationPolicy.preparedRound(
            pending: pendingNextShuffleIndices,
            generate: buildPendingNextRound
        )
        if pendingNextShuffleIndices == nil {
            pendingNextShuffleIndices = prepared
        }
        return prepared
    }

    /// Build (but don't install) the next round's shuffle order. Preview,
    /// prefetch and the actual wrap share the cached result. Avoid placing the
    /// eventual boundary track at position 0 so repeat-all doesn't feel like
    /// repeat-one even when the UI prepares the round early.
    private func buildPendingNextRound() -> [Int] {
        guard !queue.isEmpty else { return [] }
        var order = Array(0..<queue.count).shuffled()
        // The UI may prepare this round well before the current song reaches
        // the boundary. Compare against the eventual last slot of this round,
        // not the song that happened to be current when the preview opened.
        let boundaryIndex = shuffledIndices.last ?? currentIndex
        if queue.count > 1, order.first == boundaryIndex {
            let otherPos = Int.random(in: 1..<order.count)
            order.swapAt(0, otherPos)
        }
        return order
    }

    // MARK: - URL Resolution

    /// 用于日志的脱敏 URL —— 只保留 scheme+host(:port)+path, 剥掉 query 和
    /// user-info。多个源把可重放凭据放在 query 里 (Subsonic t=md5(pwd+salt)&s=salt,
    /// Synology _sid=会话令牌, 各类 api_sig/token), 而日志会被写进 caches 明文
    /// 文件并通过设置页分享出去, 原样记录等于把账号泄露给收到日志的人。query
    /// 非空时用 "?…" 占位, 既不丢失"带参数"这条诊断信息也不暴露内容。
    nonisolated private func redactedURL(_ url: URL) -> String {
        guard !url.isFileURL,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.isFileURL ? url.path : url.absoluteString
        }
        let hadQuery = !(components.query?.isEmpty ?? true)
        components.query = nil
        components.user = nil
        components.password = nil
        components.fragment = nil
        let base = components.string ?? url.absoluteString
        return hadQuery ? base + "?…" : base
    }

    private func resolvedURL(for song: Song) async throws -> URL {
        // DLNA renderer items are ephemeral and intentionally never registered
        // with SourceManager. Their filePath is the controller-provided HTTP(S)
        // URI, so seeking must reuse it directly instead of asking the library
        // source resolver for a non-existent "dlna" source.
        if song.sourceID == "dlna",
           let remoteURL = URL(string: song.filePath),
           let scheme = remoteURL.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            plog("🔗 resolvedURL for '\(song.title)': DLNA remote → \(redactedURL(remoteURL))")
            return remoteURL
        }
        if let sourceManager {
            do {
                let url = try await sourceManager.resolveURL(for: song)
                plog("🔗 resolvedURL for '\(song.title)': \(url.isFileURL ? "LOCAL" : url.scheme?.uppercased() ?? "?") → \(redactedURL(url))")
                return url
            } catch {
                plog("🔗 resolveURL failed for '\(song.title)': \(error), filePath=\(song.filePath.prefix(80))")
                if let localURL = PrimuseSandboxPathResolver.existingURL(
                    forStoredAbsolutePath: song.filePath
                ) {
                    if localURL.path != song.filePath {
                        plog("🔗 rebased stale sandbox path for '\(song.title)' → \(localURL.path)")
                    }
                    return localURL
                }
                throw error
            }
        }
        if let remoteURL = URL(string: song.filePath), remoteURL.scheme != nil {
            plog("🔗 resolvedURL for '\(song.title)': direct remote → \(redactedURL(remoteURL))")
            return remoteURL
        }
        if let localURL = PrimuseSandboxPathResolver.existingURL(
            forStoredAbsolutePath: song.filePath
        ) {
            plog("🔗 resolvedURL for '\(song.title)': file path → \(localURL.path.prefix(80))")
            return localURL
        }
        throw SourceError.fileNotFound(song.filePath)
    }

    // MARK: - Now Playing Info

    /// Tracks which cover we last loaded to avoid redundant disk reads
    private var lastArtworkFileName: String?

    /// 单调递增的封面刷新 token。当刮削回写完成、cache 失效但 coverArtFileName
    /// 字符串可能没变（hash deterministic）时, view 上的 onChange(coverRef) 不会
    /// 触发 reload, @State image 卡在旧 UIImage。CachedArtworkView 监听这个
    /// token, 任意 bump 都能强制三个封面位重新走 loadImage。
    private(set) var coverRevision: Int = 0

    func bumpCoverRevision() {
        coverRevision &+= 1
    }

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
        info[MPNowPlayingInfoPropertyMediaType] = isMusicVideoPlaybackActive
            ? MPNowPlayingInfoMediaType.video.rawValue
            : MPNowPlayingInfoMediaType.audio.rawValue

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
        let capturedFileFormat = currentSong?.fileFormat
        let capturedSourceManager = sourceManager

        Task.detached(priority: .userInitiated) { [weak self] in
            guard self != nil else { return }
            let store = MetadataAssetStore.shared

            // Tier 1: songID-based cache (透明处理 content-addressed redirect)
            var loadedImage: PlatformImage?
            let hashedName = store.expectedCoverFileName(for: songID)
            if let data = store.readCoverData(named: hashedName) {
                loadedImage = PlatformImage(data: data)
            }

            // Tier 2: legacy filename (local hashed filename, no "/" or "://")
            if loadedImage == nil, let coverRef, !coverRef.isEmpty,
               !coverRef.contains("/"), !coverRef.contains("://") {
                if let data = store.readCoverData(named: coverRef) {
                    loadedImage = PlatformImage(data: data)
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
                    defer { session.finishTasksAndInvalidate() }
                    fetchedData = try? await session.data(from: url).0
                }
                // Sidecar path on source (contains "/" but no "://")
                else if coverRef.contains("/"), let sourceID = capturedSourceID,
                        let sourceManager = capturedSourceManager {
                    if let imageURL = await sourceManager.imageURL(for: coverRef, sourceID: sourceID) {
                        let config = URLSessionConfiguration.default
                        config.timeoutIntervalForRequest = 10
                        let session = URLSession(configuration: config, delegate: SmartSSLDelegate(), delegateQueue: nil)
                        defer { session.finishTasksAndInvalidate() }
                        fetchedData = try? await session.data(from: imageURL).0
                    }
                }
                if let data = fetchedData {
                    // Cache for next time
                    await store.cacheCover(data, forSongID: songID)
                    loadedImage = PlatformImage(data: data)
                }
            }

            // Tier 4: embedded cover extraction from locally cached audio file
            if loadedImage == nil, let sourceID = capturedSourceID, let filePath = capturedFilePath,
               let sourceManager = capturedSourceManager {
                let inferredFormat = capturedFileFormat
                    ?? AudioFormat.from(fileExtension: (filePath as NSString).pathExtension)
                    ?? .mp3
                let dummySong = Song(id: "", title: "", fileFormat: inferredFormat, filePath: filePath,
                                     sourceID: sourceID, fileSize: 0, dateAdded: Date())
                if let cachedURL = await sourceManager.cachedURL(for: dummySong) {
                    let metadata = await FileMetadataReader.read(from: cachedURL)
                    if let coverData = metadata.coverArtData {
                        await store.cacheCover(coverData, forSongID: songID)
                        loadedImage = PlatformImage(data: coverData)
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
        bumpCoverRevision()
        updateNowPlayingArtworkIfNeeded()
    }

    func updateNowPlayingArtwork(_ image: PlatformImage) {
        lastArtworkFileName = currentSong?.coverArtFileName
        let artwork = Self.makeArtwork(from: image)
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPMediaItemPropertyArtwork] = artwork
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// Creates MPMediaItemArtwork with a non-isolated requestHandler closure.
    /// Must be nonisolated so the closure doesn't inherit @MainActor isolation —
    /// MediaPlayer calls the handler on a background dispatch queue.
    nonisolated private static func makeArtwork(from image: PlatformImage) -> MPMediaItemArtwork {
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

    /// 曲终停止 ── 锁定当前曲目, 等它自然播完时自动暂停。如果用户手动
    /// 切歌, `play(song:)` 会取消这个旧锁；currentSong 为空则不激活。
    func scheduleSleepAtTrackEnd() {
        cancelSleep()
        sleepStopAfterSongID = currentSong?.id
    }

    func cancelSleep() {
        sleepTimerTask?.cancel()
        sleepTimerTask = nil
        sleepTimerEndDate = nil
        sleepStopAfterSongID = nil
    }

    // MARK: - Shared Playback State

    /// Tracks the last songID for which we wrote a widget cover, to avoid redundant writes.
    private var lastWidgetCoverSongID: String?
    /// Coalesces repeated WidgetKit reload requests with identical content.
    private var lastWidgetTimelineSignature: String?

    /// macOS Widget Sync 设置页里 "立即更新" 按钮直接调这个。包装一下 private
     /// 的 updatePlaybackState, 让 mac 设置面板可以强制刷一遍 widget 状态而无需
     /// 把整个内部方法暴露成 public。
    func publishWidgetStateForMacWidgetSync() {
        updatePlaybackState()
    }

    private func updatePlaybackState() {
        #if os(macOS)
        let request = MacWidgetPlaybackPublishRequest(
            currentSong: currentSong,
            isPlaying: isPlaying,
            currentTime: currentTime,
            duration: duration,
            queueSongIDs: queue.map(\.id)
        )
        Task {
            await MacWidgetPlaybackPublisher.shared.enqueue(request)
        }
        return
        #else
        guard WidgetSettings.syncEnabled(),
              WidgetSettings.widgetEnabled(PrimuseConstants.widgetNowPlayingEnabledKey) else {
            PlaybackState.clear()
            WidgetCenter.shared.reloadAllTimelines()
            return
        }

        // Privacy scope: the user can narrow what's published into the App
        // Group container. `includesCover` gates the cover files; `includesProgress`
        // gates currentTime/duration. (`includesLyrics` is enforced by the
        // lyrics publisher, not here.)
        let scope = WidgetSettings.sharedDataScope()

        var coverName: String?
        var recentAlbumsChanged = false
        let recentAlbumsEnabled = scope.includesCover
            && WidgetSettings.widgetEnabled(PrimuseConstants.widgetRecentAlbumsEnabledKey)

        if !scope.includesCover {
            // Scope narrowed below `cover`: never write cover art, and purge any
            // files left from a wider scope so the WidgetKit extension can't keep
            // disclosing album art the user opted out of.
            clearSharedWidgetCovers()
            lastWidgetCoverSongID = nil
            if WidgetSettings.widgetEnabled(PrimuseConstants.widgetRecentAlbumsEnabledKey),
               !RecentAlbumsStore.load().isEmpty {
                // Recent-albums widget renders covers; with covers disclosed off
                // there's nothing meaningful to show, so clear its store too.
                RecentAlbumsStore.clear()
                recentAlbumsChanged = true
            }
        } else if let song = currentSong {
            let sharedCoverName = "widget_cover.png"
            let needsSharedCoverRefresh = song.id != lastWidgetCoverSongID || !sharedWidgetCoverExists(named: sharedCoverName)

            if needsSharedCoverRefresh {
                if let writtenCoverName = writeWidgetCover(song: song, fileName: sharedCoverName) {
                    coverName = writtenCoverName
                    lastWidgetCoverSongID = song.id
                } else {
                    // Current song has no usable cover. Any existing
                    // widget_cover.png belongs to the *previous* song, so
                    // reusing it would show the wrong album art for this whole
                    // track. Delete it and leave coverName nil so the widget
                    // falls back to its placeholder gradient; keep
                    // lastWidgetCoverSongID nil so the next event retries.
                    removeSharedWidgetCover(named: sharedCoverName)
                    lastWidgetCoverSongID = nil
                }

                if recentAlbumsEnabled, let albumEntry = makeRecentAlbumEntry(for: song) {
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
            if !recentAlbumsEnabled {
                RecentAlbumsStore.clear()
                recentAlbumsChanged = true
            }
        } else {
            lastWidgetCoverSongID = nil
        }

        let state = PlaybackState(
            currentSongID: currentSong?.id,
            songTitle: currentSong?.title,
            artistName: currentSong?.artistName,
            albumTitle: currentSong?.albumTitle,
            fileFormat: currentSong.map { $0.fileFormat.displayName },
            coverImageName: coverName,
            isPlaying: isPlaying,
            // Progress gated by scope: omit currentTime/duration when the user
            // hasn't granted progress disclosure (defaults to 0 via the init).
            currentTime: scope.includesProgress ? currentTime : 0,
            duration: scope.includesProgress ? duration : 0,
            queueSongIDs: queue.map(\.id)
        )
        state.save()

        let timelineSignature = widgetTimelineSignature(for: state)
        if recentAlbumsChanged || timelineSignature != lastWidgetTimelineSignature {
            lastWidgetTimelineSignature = timelineSignature
            WidgetCenter.shared.reloadAllTimelines()
        }
        #endif
    }

    /// Writes a cover image to the App Group shared container for Widget rendering.
    /// Returns the filename if successful.
    ///
    /// iOS 与 macOS 共用同一 App Group 路径与文件名约定; widget 扩展的
    /// WidgetCoverImageView / RecentAlbumCoverView 只按 coverImageName 从
    /// App Group 容器读 JPEG, 两端别无他路, 故 macOS 也必须落盘真实封面,
    /// 否则桌面 widget 永远只显示占位渐变。
    @discardableResult
    private func writeWidgetCover(song: Song, fileName: String, size: CGFloat = 300) -> String? {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: PrimuseConstants.appGroupIdentifier
        ) else { return nil }

        let store = MetadataAssetStore.shared

        // Try songID-based cache first (透明处理 content-addressed redirect)
        var coverData: Data?
        let hashedName = store.expectedCoverFileName(for: song.id)
        coverData = store.readCoverData(named: hashedName)

        // Fallback: legacy local filename
        if coverData == nil, let ref = song.coverArtFileName, !ref.isEmpty,
           !ref.contains("/"), !ref.contains("://") {
            coverData = store.readCoverData(named: ref)
        }

        guard let data = coverData else { return nil }

        let targetSize = CGSize(width: size, height: size)
        let destinationURL = containerURL.appendingPathComponent(fileName)

        /// Aspect-fill (centered crop) rect for `sourceSize` into `targetSize`.
        func aspectFillRect(sourceSize: CGSize) -> CGRect {
            let sourceAspect = sourceSize.width / sourceSize.height
            if sourceAspect > 1 {
                let scaledWidth = targetSize.height * sourceAspect
                return CGRect(x: (targetSize.width - scaledWidth) / 2, y: 0,
                              width: scaledWidth, height: targetSize.height)
            } else {
                let scaledHeight = targetSize.width / sourceAspect
                return CGRect(x: 0, y: (targetSize.height - scaledHeight) / 2,
                              width: targetSize.width, height: scaledHeight)
            }
        }

        #if os(iOS)
        guard let originalImage = UIImage(data: data) else { return nil }

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = true

        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        let resizedImage = renderer.image { context in
            UIColor.black.setFill()
            context.fill(CGRect(origin: .zero, size: targetSize))
            originalImage.draw(in: aspectFillRect(sourceSize: originalImage.size))
        }

        guard let jpegData = resizedImage.jpegData(compressionQuality: 0.8) else { return nil }

        do {
            try jpegData.write(to: destinationURL, options: .atomic)
            return fileName
        } catch {
            return nil
        }
        #elseif os(macOS)
        guard let originalImage = NSImage(data: data) else { return nil }

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(targetSize.width),
            pixelsHigh: Int(targetSize.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        rep.size = targetSize

        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        let previousContext = NSGraphicsContext.current
        NSGraphicsContext.current = context
        NSColor.black.setFill()
        NSRect(origin: .zero, size: targetSize).fill()
        // Centered aspect-fill crop is symmetric in both axes, so AppKit's
        // y-up coordinate space yields the same framing as iOS's renderer.
        originalImage.draw(
            in: aspectFillRect(sourceSize: originalImage.size),
            from: .zero,
            operation: .sourceOver,
            fraction: 1.0
        )
        context.flushGraphics()
        NSGraphicsContext.current = previousContext

        guard let jpegData = rep.representation(
            using: .jpeg,
            properties: [.compressionFactor: 0.8]
        ) else { return nil }

        do {
            try jpegData.write(to: destinationURL, options: .atomic)
            return fileName
        } catch {
            return nil
        }
        #else
        return nil
        #endif
    }

    private func sharedWidgetCoverExists(named fileName: String) -> Bool {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: PrimuseConstants.appGroupIdentifier
        ) else {
            return false
        }
        return FileManager.default.fileExists(atPath: containerURL.appendingPathComponent(fileName).path)
    }

    /// Removes a stale shared widget cover so it isn't mistaken for the current
    /// song's art when the current song has no usable cover.
    private func removeSharedWidgetCover(named fileName: String) {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: PrimuseConstants.appGroupIdentifier
        ) else { return }
        try? FileManager.default.removeItem(at: containerURL.appendingPathComponent(fileName))
    }

    /// Purges every widget cover file in the App Group container
    /// (`widget_cover.png` + `widget_album_*`). Used when the user narrows the
    /// shared-data scope below `cover`, so the WidgetKit extension stops
    /// rendering album art that's no longer disclosed. Mirrors
    /// `WidgetSharedStore.clearSharedCoverFiles()`, which is internal to
    /// PrimuseKit and not reachable from this target.
    private func clearSharedWidgetCovers() {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: PrimuseConstants.appGroupIdentifier
        ) else { return }
        let fm = FileManager.default
        try? fm.removeItem(at: containerURL.appendingPathComponent("widget_cover.png"))
        guard let entries = try? fm.contentsOfDirectory(
            at: containerURL,
            includingPropertiesForKeys: nil
        ) else { return }
        for url in entries where url.lastPathComponent.hasPrefix("widget_album_") {
            try? fm.removeItem(at: url)
        }
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
            String(state.currentTime.rounded().finiteInt()),
            String(state.duration.rounded().finiteInt())
        ].joined(separator: "|")
    }
}
