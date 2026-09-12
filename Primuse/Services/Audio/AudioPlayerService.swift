import AVFoundation
import CryptoKit
import Foundation
import ImageIO
import MediaPlayer
import PrimuseKit
import SFBAudioEngine
#if os(iOS)
import CarPlay
import UIKit
import WidgetKit
#elseif os(macOS)
import AppKit
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
final class StepCounter: @unchecked Sendable {
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
final class BufferIteratorBox: @unchecked Sendable {
    private var iterator: AudioBufferStream.AsyncIterator

    init(_ iterator: AudioBufferStream.AsyncIterator) {
        self.iterator = iterator
    }

    func next() async throws -> AVAudioPCMBuffer? {
        try await iterator.next()
    }
}

/// Result carrier used by the first-buffer timeout task group.
private struct PCMBufferBox: @unchecked Sendable {
    let value: AVAudioPCMBuffer?
}

/// Mutable handoff state for one gapless boundary. The audio scheduling
/// callback and decoder task both touch it, but all mutations are routed
/// back through `AudioPlayerService` on MainActor.
final class GaplessTransitionState: @unchecked Sendable {
    let queueGeneration: Int
    let advanceTicket: PlaybackAdvanceTicket
    var prepared: GaplessPreparedTrack?
    var bufferGate: DecodedBufferGate?
    var didBoundaryFire = false
    /// Signalled once this boundary reaches a terminal state, so the follow-up
    /// preparation can wait instead of polling for the rest of the track.
    let settlement = PlaybackScheduleSettlement()
    var shouldCancelPreparation = false {
        didSet { if shouldCancelPreparation { settle() } }
    }
    var isFullyScheduled = false {
        didSet { if isFullyScheduled { settle() } }
    }
    var didFail = false {
        didSet { if didFail { settle() } }
    }
    var boundary: PlaybackTimelineTracker.BoundaryToken?

    init(queueGeneration: Int, advanceTicket: PlaybackAdvanceTicket) {
        self.queueGeneration = queueGeneration
        self.advanceTicket = advanceTicket
    }

    /// 类型本身不带 actor 隔离, 而 settlement 是 MainActor 的; 这里跳一次
    /// MainActor 再落闩。settle 幂等, 等待方唤醒后还会重查所有 guard,
    /// 所以晚一个 hop 不影响正确性。
    private func settle() {
        Task { @MainActor [settlement] in
            settlement.settle()
        }
    }
}

struct GaplessPreparedTrack: @unchecked Sendable {
    let queueEntryID: UUID
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

#if os(iOS)
/// Compact projection used by the Watch bridge. It hashes the complete queue
/// in one pass but retains only the prefix that fits WatchConnectivity's
/// payload budget, avoiding several full `[Song]` and string-array copies on
/// the main actor for large queues.
struct WatchQueueDigestSnapshot: Sendable {
    let songIDs: [String]
    let titles: [String]
    let artists: [String]
    let totalCount: Int
    let digest: Int
    let estimatedPayloadBytes: Int

    var isTruncated: Bool { songIDs.count < totalCount }
}
#endif

struct PreparedPlaybackSessionRestore: Sendable {
    let plan: PlaybackSessionRestorationPlan
    let entries: [QueueEntry]
    let loadFinishedAt: TimeInterval
    let planFinishedAt: TimeInterval
    let lookupFinishedAt: TimeInterval
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
struct MacWidgetPlaybackPublishRequest: Sendable {
    let currentSong: Song?
    let artistDisplayName: String?
    let isPlaying: Bool
    let sampledAt: Date
    let currentTime: TimeInterval
    let duration: TimeInterval
    let queueSongIDs: [String]
    let playbackKind: PlaybackKind
    let radioStationID: String?
    let repeatMode: RepeatMode
    let isLiked: Bool?
}

/// Serial, latest-wins widget publisher for macOS.
///
/// The detached worker owns every potentially blocking App Group operation.
/// While it is running, new progress events replace `pending` instead of
/// spawning more writers. If macOS stalls one filesystem call, the player UI
/// remains responsive and the pending memory footprint stays bounded to one
/// snapshot.
actor MacWidgetPlaybackPublisher {
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

                if recentAlbumsEnabled,
                   let albumEntry = makeRecentAlbumEntry(
                    for: song,
                    artistName: request.artistDisplayName
                   ) {
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
            artistName: request.artistDisplayName,
            albumTitle: request.currentSong?.albumTitle,
            fileFormat: request.currentSong.map { $0.fileFormat.displayName },
            coverImageName: coverName,
            isPlaying: request.isPlaying,
            currentTime: scope.includesProgress ? request.currentTime : 0,
            duration: scope.includesProgress ? request.duration : 0,
            queueSongIDs: request.queueSongIDs,
            playbackKind: request.playbackKind,
            radioStationID: request.radioStationID,
            repeatMode: request.repeatMode,
            isLiked: request.isLiked,
            updatedAt: request.sampledAt
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

    private nonisolated static func makeRecentAlbumEntry(
        for song: Song,
        artistName: String?
    ) -> RecentAlbumEntry? {
        guard let title = song.albumTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else { return nil }
        let artist = artistName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
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
            state.playbackKind?.rawValue ?? PlaybackKind.track.rawValue,
            state.radioStationID ?? "",
            state.repeatMode?.rawValue ?? RepeatMode.off.rawValue,
            state.isLiked == true ? "1" : "0",
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
    let sourceManager: SourceManager?
    let library: MusicLibrary?
    @ObservationIgnored private weak var playbackMetadataBackfill: MetadataBackfillService?
    @ObservationIgnored var playbackMetadataSourceType: ((String) -> MusicSourceType?)?
    @ObservationIgnored private var playbackMetadataTask: Task<Void, Never>?
    @ObservationIgnored private var playbackMetadataTaskIdentity: PlaybackMetadataIdentity?
    @ObservationIgnored private var playbackMetadataTaskToken: UUID?
    @ObservationIgnored private var playbackMetadataFailureCounts: [PlaybackMetadataIdentity: Int] = [:]
    @ObservationIgnored var artistNameConfiguration: ArtistNameConfiguration
    let playbackSessionStore: PlaybackSessionStore
    /// 快照仍然在主 actor 上采集, 但 JSON 编码与原子写交给这个协调器在后台
    /// 完成。它用递增的 generation 合并请求: 只有最新的状态会落盘, 更新的
    /// 请求会顶掉还没写出去的旧请求, 最终状态永远不会丢。
    @ObservationIgnored let playbackSessionPersistence:
        PlaybackSessionPersistenceCoordinator
    @ObservationIgnored var playbackSessionPersistGeneration: UInt64 = 0
    var playbackSessionRestoreLifecycle = PlaybackSessionRestoreLifecycle()
    var isRestoringPlaybackSession = false

    var currentSong: Song? {
        didSet {
            #if os(iOS)
            prepareLyricsForSystemSurfaces(previousSong: oldValue)
            #endif
            playbackMetadataSongDidChange(from: oldValue, to: currentSong)
        }
    }
    var isPlaying = false {
        didSet {
            if isPlaying && !isLoading { schedulePlaybackMetadataReadIfNeeded() }
        }
    }
    var playbackKind: PlaybackKind = .track
    var currentRadioStation: RadioStation?
    var radioMetadataTitle: String?
    /// 电台此刻推送的完整元数据(拆好的艺术家/曲名 + 配图地址)。
    /// 播放页要做「正在播放」这类展示时用它，而不是自己再解析一遍文本。
    var radioNowPlaying: RadioLiveMetadata?
    /// 当前曲目的配图。电台给了就用它盖住台标 —— 那是此刻更贴切的画面。
    var radioNowPlayingArtworkURL: String?
    /// 本次收听里出现过的曲目/节目，最新的在最前。电台没有播放列表，
    /// 这条历史就是听众唯一能回看「刚才那首叫什么」的地方。
    var radioTitleHistory: [RadioTitleHistoryEntry] = []
    /// 这条流带的字幕轨。广播电台基本都是空的。
    var radioSubtitleTracks: [RadioSubtitleTrack] = []
    var radioSelectedSubtitleTrackID: String?
    /// 当前该显示的字幕文本。
    var radioSubtitleText: String?
    var radioStreamFormat: RadioStreamFormat = .automatic
    var radioBitRate: Int?
    var isLiveRadio: Bool { playbackKind == .liveRadio }
    var canSwitchRadioStation: Bool { isLiveRadio && radioStationOrder.count > 1 }
    var playbackCapabilities: PlaybackPresentationCapabilities {
        .capabilities(for: playbackKind)
    }
    /// 「歌播完了但 queue 没下一首」的状态 —— Apple Music / Spotify 风格的
    /// "已播完待重播"。currentSong / queue / currentIndex 全保留, 只是
    /// 引擎停了 + currentTime = 0 + isPlaying = false。用户点 play 会从头
    /// 重放当前曲。这个状态存在的意义: 别让 currentSong 变 nil ——
    /// 否则 NowPlayingView / 刮削 sheet / mini player 全是空白屏 (因为
    /// 它们都靠 currentSong 渲染)。
    ///
    /// 触发: handleTrackEnd .off + nextSongInQueue() == nil
    /// 退出: play(song:) / stop() / resume() (resume 会把当前歌重新 play)
    var isAtTrackEnd = false
    /// `currentTimeAnchor` 在 didSet 里自动同步 wall-clock，配合 `interpolatedTime(at:)`
    /// 在 0.5s 引擎采样间隙内做线性外推，让 60Hz 字级歌词动画无抖。
    var currentTime: TimeInterval = 0 {
        didSet {
            currentTimeAnchor = Date()
            handoffCurrentTime = currentTime
            #if os(iOS)
            publishLockScreenLyricsIfNeeded()
            #endif
        }
    }
    var duration: TimeInterval = 0
    var isLoading = false {
        didSet {
            if !isLoading && isPlaying { schedulePlaybackMetadataReadIfNeeded() }
        }
    }
    private(set) var lastPlaybackError: String?
    /// `currentSong` is published before remote resolution finishes, so it
    /// cannot tell resume whether a local decoder has scheduled any audio.
    @ObservationIgnored var hasPreparedLocalPlayback = false
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

    @ObservationIgnored private var systemAudioPlayer: AVPlayer?
    @ObservationIgnored private var systemAudioStreamingLoader: SystemAudioStreamingLoader?
    @ObservationIgnored var systemAudioStartupWatchdog: Task<Void, Never>?
    @ObservationIgnored var systemAudioPlaybackDidStart = false
    @ObservationIgnored var pendingSystemAudioSeek: (
        playID: UUID,
        songID: String,
        time: TimeInterval,
        shouldStart: Bool
    )?
    var isSystemAudioPlaybackActive = false
    private var systemAudioFallbackContext: (
        song: Song,
        url: URL,
        streamEpoch: UInt64
    )?

    var isSystemMediaPlaybackActive: Bool {
        isMusicVideoPlaybackActive || isSystemAudioPlaybackActive
    }

    var activeSystemMediaPlayer: AVPlayer? {
        isSystemAudioPlaybackActive ? systemAudioPlayer : musicVideoPlayer
    }

    func handoffPlaybackTimeSnapshot() -> TimeInterval {
        handoffCurrentTime
    }

    /// 在 `currentTime` 与下一次 0.5s 采样之间做线性外推，每次 currentTime
    /// 真实更新（didSet 重置 anchor）就跟引擎报告时间校准一次,不会累积漂移。
    func interpolatedTime(at date: Date = Date()) -> TimeInterval {
        PlaybackClockFreezePolicy.frozenTime(
            cachedCurrentTime: currentTime,
            currentTimeAnchor: currentTimeAnchor,
            eventTime: date,
            isAdvancing: isPlaying && !isLoading,
            duration: duration
        )
    }

    /// Stored backing for the queue. Each entry pairs a Song with a
    /// stable UUID — see `QueueEntry`. Mutate via `setQueue`,
    /// `clearQueue`, `moveQueueItems`, or `syncSongMetadata`; do NOT
    /// hand-edit from outside.
    @ObservationIgnored private var queueSnapshotRevision = 0
    var queueEntries: [QueueEntry] = [] {
        didSet { queueSnapshotRevision &+= 1 }
    }
    /// Backward-compatible read-only view over the queue's songs.
    /// Internal callers and observers keep using `player.queue` —
    /// the @Observable macro tracks reads through `queueEntries`,
    /// so SwiftUI re-renders correctly when entries change.
    var queue: [Song] { queueEntries.map(\.song) }
    /// Queue metadata accessors for views that only need a count or one row.
    /// Avoid materializing a complete `[Song]` on every playback-time update.
    var queueCount: Int { queueEntries.count }
    /// Lets non-UI bridges skip materializing the complete queue until its
    /// rows or metadata have actually changed.
    var watchQueueSnapshotRevision: Int { queueSnapshotRevision }
    #if os(iOS)
    func makeWatchQueueDigestSnapshot(
        byteBudget: Int,
        perItemOverhead: Int,
        artistConfiguration: ArtistNameConfiguration = .defaultValue
    ) -> WatchQueueDigestSnapshot {
        let safeBudget = max(0, byteBudget)
        let safeOverhead = max(0, perItemOverhead)
        let expectedPrefixCount = min(queueEntries.count, safeBudget / 64)
        var songIDs: [String] = []
        var titles: [String] = []
        var artists: [String] = []
        songIDs.reserveCapacity(expectedPrefixCount)
        titles.reserveCapacity(expectedPrefixCount)
        artists.reserveCapacity(expectedPrefixCount)

        var hasher = Hasher()
        var retainedBytes = 0
        var acceptsMoreRows = safeBudget > 0
        for entry in queueEntries {
            let songID = entry.song.id
            let title = entry.song.title
            let artist = entry.song.displayArtistName(configuration: artistConfiguration) ?? ""
            hasher.combine(songID)
            hasher.combine(title)
            hasher.combine(artist)

            guard acceptsMoreRows else { continue }
            let rowBytes = songID.utf8.count + title.utf8.count
                + artist.utf8.count + safeOverhead
            guard retainedBytes + rowBytes < safeBudget else {
                acceptsMoreRows = false
                continue
            }
            songIDs.append(songID)
            titles.append(title)
            artists.append(artist)
            retainedBytes += rowBytes
        }

        return WatchQueueDigestSnapshot(
            songIDs: songIDs,
            titles: titles,
            artists: artists,
            totalCount: queueEntries.count,
            digest: hasher.finalize(),
            estimatedPayloadBytes: retainedBytes
        )
    }
    #endif
    func queuedSong(at index: Int) -> Song? {
        guard queueEntries.indices.contains(index) else { return nil }
        return queueEntries[index].song
    }
    var canRemoveUpcomingQueueEntries: Bool {
        !(isAppleMusicMode && !isPrimuseManagingAppleMusicQueue)
    }
    var currentIndex: Int = 0
    var shuffleEnabled = false {
        didSet {
            guard shuffleEnabled != oldValue else { return }
            defer {
                if !isRestoringPlaybackSession {
                    persistPlaybackSession()
                }
            }
            // mirror task 同步 Apple Music shuffle 时跳过 — 不要再写回 AM
            // 触发 polling 抖动。本地播放时正常重建 shuffle order。
            if isMirroringFromAppleMusic { return }
            if isAppleMusicMode && !isPrimuseManagingAppleMusicQueue {
                AppServices.shared.appleMusic.setAppleMusicShuffle(shuffleEnabled)
                return
            }
            cancelPreparedQueueSuccessor()
            rebuildShuffleOrder()
            prefetchNextSong()
        }
    }
    var repeatMode: RepeatMode = .off {
        didSet {
            guard repeatMode != oldValue else { return }
            defer {
                if !isRestoringPlaybackSession {
                    updatePlaybackState()
                }
            }
            if isMirroringFromAppleMusic { return }
            if isAppleMusicMode && !isPrimuseManagingAppleMusicQueue {
                AppServices.shared.appleMusic.setAppleMusicRepeat(repeatMode)
                return
            }
            // Track-end, gapless and crossfade callbacks all re-read the
            // current repeat mode before committing their successor. Reusing
            // the active transport is therefore both safe and immediate.
            // `invalidateQueueTransitions()` is reserved for changes that
            // replace current transport ownership; it rebuilds the decoder
            // with a seek and creates an audible pause for policy-only edits.
            prefetchNextSong()
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
    var isMirroringFromAppleMusic = false

    /// MusicKit renders a contiguous segment; Primuse retains the complete
    /// queue and each occurrence's identity across providers and edits.
    var isPrimuseManagingAppleMusicQueue = false
    @ObservationIgnored var appleMusicQueueUpdateTask: Task<Void, Never>?

    // MARK: - DLNA Casting (推到外部 Renderer)

    /// 当前正在投屏的 RemoteRenderer。nil = 本机播放。
    /// 跟 isAppleMusicMode 一样作为路由开关: togglePlayPause / next / previous /
    /// seek 检测到 isCastingMode 后走 RemoteRendererController 而不是 audioEngine。
    var castingRenderer: RemoteRenderer?

    /// 跟当前 castingRenderer 对应的 SOAP controller。生命周期跟 castingRenderer 绑定。
    var castingController: RemoteRendererController?
    /// Orders asynchronous renderer commands. Any newer Play/Pause/ownership
    /// change makes an older network response observationally stale.
    var castingCommandGeneration: UInt64 = 0

    /// 1Hz 轮询 GetPositionInfo + GetTransportInfo 同步进度 / 播放状态。
    var castingPositionTask: Task<Void, Never>?
    /// Replacement Apple Music requests await the same renderer Stop instead
    /// of observing a temporarily detached controller and starting early.
    var appleMusicCastingHandoffTask: Task<Bool, Never>?
    var appleMusicCastingHandoffID = UUID()
    var appleMusicCastingHandoffController: RemoteRendererController?
    var appleMusicCastingHandoffRenderer: RemoteRenderer?

    var isCastingMode: Bool { castingRenderer != nil }
    var isPlaybackActuallyActive: Bool {
        if isLiveRadio || isAppleMusicMode || isCastingMode || isSystemMediaPlaybackActive {
            return isPlaying
        }
        return isPlaying && audioEngine.isActuallyPlaying
    }
    /// Canonical state for in-app controls, widgets and system transport UI.
    /// `isPlaying` is retained as the mirrored backend flag; this additionally
    /// verifies local engine output so a stopped engine cannot show Pause.
    var isPlaybackActive: Bool { isPlaybackActuallyActive }
    var appleMusicPlaybackTask: Task<Void, Never>?
    var appleMusicTimeoutTask: Task<Void, Never>?
    var activeAppleMusicRequestID: UUID?
    var pendingAppleMusicRestoredPosition: (songID: String, time: TimeInterval)?
    private var appleMusicMirrorTask: Task<Void, Never>?
    /// Invalidates suspended observation tasks when playback changes owner.
    /// Cancellation alone is insufficient because a checked continuation can
    /// still resume once after `stopAppleMusic()` mutates the observed state.
    private var appleMusicMirrorGeneration: UInt64 = 0
    private var rescuedAppleMusicLyricsAliases: Set<String> = []
    private var musicVideoTimeObserver: Any?
    private var musicVideoEndObserver: NSObjectProtocol?
    private var musicVideoStatusObservation: NSKeyValueObservation?
    private var musicVideoTimeControlObservation: NSKeyValueObservation?
    private var musicVideoFailedObserver: NSObjectProtocol?
    var musicVideoObserverGeneration: UInt64 = 0
    var pendingMusicVideoPlayID: UUID?
    private struct MusicVideoSeekActivityEvidence {
        let itemID: String
        let playID: UUID
        let observerGeneration: UInt64
    }
    var musicVideoSeekActivityEvidence: MusicVideoSeekActivityEvidence?
    let radioPlaybackController = RadioPlaybackController()
    var radioLiveStreamSource: RadioLiveStreamSource?
    var radioUsesDecodedTransport = false
    var radioPrefersDecodedTransport = false
    var radioDidAttemptDecodedFallback = false
    var radioDecodedFallbackNeedsValidation = false
    /// Ephemeral direct URL for the active station. Source-backed streams can
    /// contain access tokens, so this value never enters `RadioStation`,
    /// persistence, widgets, or CloudKit payloads.
    var radioResolvedStreamURL: URL?
    var pendingRadioResolutionID: UUID?
    var radioStationOrder: [RadioStation] = []
    var radioReconnectTask: Task<Void, Never>?
    var radioReconnectAttempt = 0
    var radioPlaybackStartedAt: Date?
    /// AVAssetResourceLoader 对 delegate 是弱引用, 流式播放期间必须强持有。
    private var musicVideoStreamingLoader: MusicVideoStreamingLoader?
    #if os(iOS)
    private var isCarPlaySceneActive = false
    private var isCarAudioRouteConnected = false
    private var carPlayConnectObserver: NSObjectProtocol?
    private var carPlayDisconnectObserver: NSObjectProtocol?
    private var carAudioRouteObserver: NSObjectProtocol?
    #endif

    var canPlayMusicVideo: Bool {
        guard let song = currentSong,
              song.mvPath?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return false
        }
        return !isLiveRadio && !isAppleMusicMode && !isCastingMode && !shouldForceAudioOnly
    }

    private var shouldForceAudioOnly: Bool {
        #if os(iOS)
        return isCarPlaySceneActive || isCarAudioRouteConnected
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
    var shuffledIndices: [Int] = []
    var shufflePosition: Int = 0
    /// Pre-computed next round used by repeat-all wrap-around. Generated on
    /// first demand from queue preview or prefetch so `nextSongInQueue` and
    /// `advanceToNextIndex` adopt exactly the visible order. Cleared on any
    /// structural change to `queue` / shuffle state.
    @ObservationIgnored var pendingNextShuffleIndices: [Int]?
    /// Invalidates prepared gapless transitions when queue order changes.
    var queueGeneration = 0

    // MARK: - Decoder Tracking (for seek)
    /// Tracks which decoder pipeline produced the currently-playing audio
    /// stream so seek/crossfade/recovery can reproduce the exact same path.
    /// `cloudStream` means SFBAudio decoding from a `CloudPlaybackSource`
    /// `InputSource` (Range-fetch + sparse cache). Seeking that path
    /// requires building a NEW `InputSource` — feeding the
    /// `primuse-stream://` URL to SFB's URL-based opener fails because
    /// the scheme isn't registered with the file system.
    enum DecoderKind: Sendable, Equatable { case native, ffmpeg, streaming, httpStream, cloudStream, assetReader }
    struct CommittedCrossfade {
        let attemptID: UUID
        let playID: UUID
        let song: Song
        let url: URL
        let decoderKind: DecoderKind
        /// 提交交叉淡入时正在播放的那一首的 playID。ramp 结束前它仍然拥有
        /// primary 节点, 解码泵靠它判断自己还能不能继续投递。
        let outgoingPlayID: UUID
    }
    enum CrossfadeCompletionMode: Equatable {
        case activePlayback
        case preserveCachedProgress
    }
    var activeDecoderKind: DecoderKind = .native
    var activeDSDPlaybackMode: DSDPlaybackMode = .pcm

    // MARK: - Sleep Timer
    var sleepTimerEndDate: Date?
    var sleepTimerTask: Task<Void, Never>?
    /// "曲终停止" 模式: 持有当前歌曲的 id, 一旦切到下一首 (或 currentSong
    /// 变 nil) 立即 pause。比固定分钟数更智能 ── 不会在曲子中间硬切。
    var sleepStopAfterSongID: String? {
        didSet { if sleepStopAfterSongID != oldValue { synchronizeAppleMusicQueue() } }
    }
    var isSleepTimerActive: Bool { sleepTimerEndDate != nil || sleepStopAfterSongID != nil }

    var displayLink: Timer?
    @ObservationIgnored var playbackClockTickGate = PlaybackClockTickGate()
    /// Completion callbacks from AVAudioPlayerNode are occasionally lost after
    /// route changes. Keep a near-end progress watchdog so a drained first
    /// track cannot leave a non-empty queue stuck forever.
    var lastEngineProgressSample: TimeInterval?
    var nearEndStallSampleCount = 0
    static let trackEndStallSampleThreshold = 4
    let nativeDecoder = NativeAudioDecoder()
    let ffmpegDecoder = FFmpegAudioDecoder()
    let radioFLACDecoder = RadioFLACAudioDecoder()

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
    let assetReaderDecoder = AssetReaderDecoder()
    private let streamingDecoder = StreamingDownloadDecoder()
    private struct ActiveStreamingDownloadPreparation {
        let id: UUID
        let song: Song
        let control: StreamingDownloadSessionControl
    }
    private struct StreamingDownloadRetirement {
        let id: UUID
        /// 退役任务收尾时要 finalize 的曲目。finalizeStreamingSession 是按
        /// .partial 路径定位会话的, 所以重新播放同一首之前必须先等它跑完。
        let songID: String
        let task: Task<Void, Never>
    }
    @ObservationIgnored var activeStreamingDownloadPreparation:
        ActiveStreamingDownloadPreparation?
    @ObservationIgnored private var streamingDownloadRetirement:
        StreamingDownloadRetirement?
    var decodingTask: Task<Void, Never>?
    var prefetchTask: Task<Void, Never>?
    var gaplessPreparationTask: Task<Void, Never>?
    var gaplessFollowupTask: Task<Void, Never>?
    var crossfadeStartupTask: Task<Void, Never>?
    var crossfadeDecodingTask: Task<Void, Never>?
    var crossfadeAttemptID: UUID?
    var committedCrossfade: CommittedCrossfade? {
        didSet { syncPumpLease() }
    }
    /// swapPlayerNodes() 之后, crossfade 解码任务正在喂的那个物理节点已经
    /// 从 crossfade 节点变成 primary 节点。该任务必须改用 scheduleBuffer
    /// (primary) 继续投递, 否则 buffer 会落到换出后被 stop/reset/静音的旧
    /// 节点上, 导致 swap 后剩余音频丢失(歌中途静音)。completeCrossfade 置
    /// true, startCrossfade 每次重置为 false。两者都在 MainActor, 不会
    /// 与解码循环的单条 schedule 语句交错。
    var crossfadeSwapDone = false
    var crossfadeTimer: Timer?
    var crossfadeTimerAttemptID: UUID?
    var crossfadeTriggered = false
    @ObservationIgnored var silenceProfiles: [String: AudioSilenceProfile] = [:]
    @ObservationIgnored var smartMixAnalyses: [String: SmartMixTrackAnalysis] = [:]
    private struct SmartMixPlatformAnalysisTask {
        let id: UUID
        let task: Task<Void, Never>
    }
    @ObservationIgnored private var smartMixPlatformAnalysisTasks: [
        String: SmartMixPlatformAnalysisTask
    ] = [:]
    /// Crossfade 提交后 currentSong 已经切到淡入曲, 但 primary node 在 ramp
    /// 完成前仍属于淡出曲。进度更新据此改读 crossfade node 的独立时钟,
    /// swap 后再无缝回到 primary node。
    var isCrossfading = false {
        didSet { syncPumpLease() }
    }
    var playID: UUID? {
        didSet { syncPumpLease() }
    }
    /// 解码泵不再跑在 MainActor 上, 所以它们无法直接读 playID / crossfade 状态。
    /// 这三个值每次变化都推到 lease 里, 泵按缓冲逐块同步查询归属, 既不用回主
    /// actor, 判定规则也仍然只有 `CrossfadePumpContinuationPolicy` 一处。
    ///
    /// 交叉淡入在 commit 时就把 playID 轮换给下一首, 但换出的那一首还要继续
    /// 播放完整段 ramp。喂 primary 节点的解码泵因此在转场结束(或被取消)之前
    /// 保留调度资格, 否则 overlap 超过 `decodedAudioLookahead` 时淡出轨会在
    /// ramp 中途断流, 直接变成静音。
    @ObservationIgnored let pumpLease = PlaybackOwnershipLease<UUID>()
    @ObservationIgnored var activeDecodedBufferGate: DecodedBufferGate?
    var activeDecodedBufferGatePlayID: UUID?
    var decodedBufferUnhealthySampleCount = 0
    var decodedBufferHealthySampleCount = 0
    var decodedBufferRecoveryAttempts = 0
    var decodedBufferRecoveryInProgress = false
    var lastDecodedBufferSampleUptime: TimeInterval?
    var decodedBufferDiagnosticUnderflowStartedAt: TimeInterval?
    var decodedBufferDiagnosticEpisodeCount = 0
    var lastDecodedBufferRecoveryAt: Date?

    private var errorDismissTask: Task<Void, Never>?
    @ObservationIgnored var interruptionResumePolicy = PlaybackInterruptionResumePolicy()
    @ObservationIgnored var playbackAdvancePolicy = PlaybackAdvanceEligibilityPolicy()
    @ObservationIgnored var localPipelineAdvanceTicket: PlaybackAdvanceTicket?
    private struct ConfigurationRecoveryActivityEvidence {
        let itemID: String
        var rebuildPlayID: UUID?
    }
    var configurationRecoveryOwnerPlayID: UUID?
    /// The AirPlay-return rebuild deliberately toggles AVAudioSession inactive
    /// and active while retaining one play generation. Both transitions may
    /// emit engine configuration notifications; absorb them only while that
    /// generation still targets the built-in route.
    var localRouteFocusRecoveryOwnerPlayID: UUID?
    var configurationRecoveryActivityEvidence: ConfigurationRecoveryActivityEvidence?
    private var configurationRecoveryTask: Task<Void, Never>?
    /// A hardware-configuration candidate that may recover only after a short
    /// settle window. An actual interruption cancels it and owns all resume
    /// authorization through PlaybackInterruptionResumePolicy instead.
    private var configurationRecoveryPendingSongID: String?
    private var appActivationInterruptionRecoveryTask: Task<Void, Never>?
    private static let appActivationInterruptionRecoveryAttemptLimit = 4
    private var bluetoothHFPResumeWatchdogTask: Task<Void, Never>?
    var lastPublishedPlaybackWasActive = false
    @ObservationIgnored var nowPlayingTransportRepublishGeneration: UInt64 = 0
    var needsPlaybackRecovery = false
    var pendingRecoveryTime: TimeInterval = 0
    /// A restored queue has no live decoder to preserve. Its first remote Play
    /// may try a Range seek, but must never wait for complete-file
    /// materialization merely to reconstruct a cold process.
    var pendingRecoveryIsColdSessionRestore = false
    /// 其他 app 的录音会话把蓝牙切到 HFP 时挂起的曲目。此刻
    /// startPlaying 会 setActive 抢回会话、打断对方录音, 只能等路由
    /// 离开 HFP 后由 attemptBluetoothHFPDeferredResume 消费。绑定曲目 ID
    /// 可防止挂起期间切歌后恢复到错误的播放 generation。
    private var bluetoothHFPSuspendedSongID: String?

    /// 最近一段时间 gapless boundary 触发的时间戳, 用于侦测 partial-cache
    /// 引起的死循环 (boundary 反复在几秒内连续触发, 队列里 1-2 首坏歌
    /// 互相切来切去)。窗口外的记录会被丢掉。
    var recentBoundaryTimes: [Date] = []
    static let boundaryStormWindow: TimeInterval = 10
    static let boundaryStormThreshold = 4

    /// A queue whose source is unavailable can otherwise recurse through every
    /// item in a few milliseconds. Keep ordinary corrupt-file skipping useful,
    /// but bound one continuous failure chain so UI/log/CPU remain responsive.
    var isFailureAdvanceChainActive = false
    var consecutiveFailureAdvanceCount = 0
    static let maxConsecutiveFailureAdvances = 8

    /// Seconds of buffered audio we let drain before forcibly advancing
    /// after a mid-stream decode error. Without this cap, the ~100 buffers
    /// already scheduled to the playerNode play out for ~20s before
    /// `autoAdvanceAfterFailure` fires — looks like the player is frozen
    /// (most painfully on CarPlay where the user has no other UI to fall
    /// back to). 3s is enough that the user hears "this song stuttered"
    /// rather than a sudden cut, but short enough to feel responsive.
    private static let midStreamErrorGrace: TimeInterval = 3
    /// Target decoded PCM duration scheduled-but-not-yet-played on the player
    /// node. Counting buffers alone is unsafe: NativeAudioDecoder usually emits
    /// ~0.2s chunks, while FFmpeg DTS frames can be only ~10ms. Eight seconds of
    /// duration-based lookahead keeps realtime playback resilient when a large
    /// queue scroll, metadata scrape, or remote artwork load briefly delays the
    /// main-actor scheduling loop. The duration cap still bounds PCM residency.
    /// nonisolated: 解码泵的缓冲测量已经跑在主 actor 之外, 需要在那里读到它。
    nonisolated static let decodedAudioLookahead: TimeInterval = 8
    /// Duration alone is not a memory bound for multichannel/hi-res PCM.
    /// Keep ordinary stereo tracks at the duration watermark while capping
    /// unusually wide or high-rate formats to a predictable resident size.
    static let maxInFlightDecodedBytes = 32 * 1024 * 1024
    /// Hard cap for pathological tiny/invalid buffers. Duration remains the
    /// primary bound, so normal PCM residency stays around the lookahead window.
    static let maxInFlightDecodedBufferCount = 384
    static let decodedBufferEmptyThreshold: TimeInterval = 0.05
    static let requiredDecodedBufferUnhealthySamples = 3
    static let maxDecodedBufferRecoveryAttempts = 2
    static let decodedBufferRecoveryCooldown: TimeInterval = 8

    nonisolated static func decodedBufferDuration(_ buffer: AVAudioPCMBuffer) -> TimeInterval {
        let sampleRate = buffer.format.sampleRate
        guard sampleRate.isFinite, sampleRate > 0, buffer.frameLength > 0 else {
            // Preserve the old 16-buffer behavior when a decoder reports an
            // unusable format rather than letting hundreds of buffers queue.
            return decodedAudioLookahead / 16
        }
        return Double(buffer.frameLength) / sampleRate
    }

    nonisolated static func decodedBufferByteCount(_ buffer: AVAudioPCMBuffer) -> Int {
        let audioBuffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let reportedBytes = audioBuffers.reduce(into: 0) {
            $0 += Int($1.mDataByteSize)
        }
        if reportedBytes > 0 { return reportedBytes }

        // Some decoder/converter combinations leave mDataByteSize at zero
        // even though frameLength is valid. Preserve the byte watermark by
        // deriving the PCM footprint from the stream description instead of
        // silently falling back to duration-only admission.
        let bytesPerFrame = Int(buffer.format.streamDescription.pointee.mBytesPerFrame)
        return Int(buffer.frameLength) * bytesPerFrame * max(1, audioBuffers.count)
    }

    func scheduleTrackedDecodedBuffer(
        _ buffer: AVAudioPCMBuffer,
        onCrossfadeNode: Bool = false,
        gate: DecodedBufferGate
    ) async {
        let bufferedDuration = Self.decodedBufferDuration(buffer)
        let bufferedByteCount = Self.decodedBufferByteCount(buffer)
        await gate.acquire(
            duration: bufferedDuration,
            byteCount: bufferedByteCount
        )
        guard !Task.isCancelled else { return }

        let completion: @Sendable (AVAudioPlayerNodeCompletionCallbackType) -> Void = { _ in
            gate.release(
                duration: bufferedDuration,
                byteCount: bufferedByteCount
            )
        }
        if onCrossfadeNode {
            audioEngine.scheduleCrossfadeBuffer(
                buffer,
                completionCallbackType: .dataPlayedBack,
                completionHandler: completion
            )
        } else {
            audioEngine.scheduleBuffer(
                buffer,
                completionCallbackType: .dataPlayedBack,
                completionHandler: completion
            )
        }
    }
    static let firstBufferTimeoutSeconds = 35
    private static let remoteFallbackFirstBufferTimeoutSeconds = 60
    static let dlnaSourceID = "dlna"

    private struct PlaybackMetadataIdentity: Hashable, Sendable {
        let songID: String
        let sourceID: String
        let filePath: String
        let revision: String?
        let fileSize: Int64

        init(_ song: Song) {
            songID = song.id
            sourceID = song.sourceID
            filePath = song.filePath
            revision = song.revision
            fileSize = song.fileSize
        }
    }

    let playbackSettings: PlaybackSettingsStore
    @ObservationIgnored private let activateAudioSession: @MainActor (Bool) throws -> Void

    init(
        sourceManager: SourceManager? = nil,
        library: MusicLibrary? = nil,
        playbackSettings: PlaybackSettingsStore = PlaybackSettingsStore(),
        playbackSessionStore: PlaybackSessionStore = PlaybackSessionStore(),
        activateAudioSession: @escaping @MainActor (Bool) throws -> Void = {
            try AudioSessionManager.shared.requirePlaybackSession(reacquiringLocalRouteFocus: $0)
        }
    ) {
        self.sourceManager = sourceManager
        self.library = library
        artistNameConfiguration = library?.artistNameConfiguration
            ?? ArtistNameConfiguration.load(from: .standard)
        self.playbackSettings = playbackSettings
        self.playbackSessionStore = playbackSessionStore
        self.playbackSessionPersistence = PlaybackSessionPersistenceCoordinator(
            store: playbackSessionStore
        )
        self.activateAudioSession = activateAudioSession
        audioEngine = AudioEngine()
        equalizerService = EqualizerService(audioEngine: audioEngine)
        audioEffectsService = AudioEffectsService(audioEngine: audioEngine, settingsStore: playbackSettings)
        applySpatialAudioSettings()
        applyPlaybackRate()
        observeSpatialAudioSettings()
        observePlaybackRate()
        observeOutputPipelineSettings()
        NotificationCenter.default.addObserver(
            forName: .primuseArtistNameConfigurationDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let configuration = notification.object as? ArtistNameConfiguration else { return }
            Task { @MainActor [weak self, configuration] in
                guard let self else { return }
                self.artistNameConfiguration = configuration.normalized()
                self.updateNowPlayingInfo()
                self.updatePlaybackState()
            }
        }
        NotificationCenter.default.addObserver(
            forName: .primuseSourceSecurityScopeWillChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let sourceID = notification.userInfo?["sourceID"] as? String else {
                return
            }
            MainActor.assumeIsolated {
                guard let self, self.currentSong?.sourceID == sourceID else { return }
                self.suspendPlaybackPreservingSelection(
                    reason: "source-security-scope-change"
                )
            }
        }
        #if os(iOS)
        observeCarAudioRouteState()
        observeLockScreenLyricsSetting()
        observeLockScreenLyricsChanges()
        observeLikedSongChanges()
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
        NotificationCenter.default.addObserver(
            forName: .primuseRadioStationsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshRadioStationOrder()
            }
        }
    }

    func configurePlaybackMetadataBackfill(
        _ service: MetadataBackfillService,
        sourceType: @escaping (String) -> MusicSourceType?
    ) {
        playbackMetadataBackfill = service
        playbackMetadataSourceType = sourceType
        if isPlaying && !isLoading {
            schedulePlaybackMetadataReadIfNeeded()
        }
    }

    private func playbackMetadataSongDidChange(from oldSong: Song?, to newSong: Song?) {
        let oldIdentity = oldSong.map(PlaybackMetadataIdentity.init)
        let newIdentity = newSong.map(PlaybackMetadataIdentity.init)
        if oldIdentity != newIdentity, let oldIdentity {
            playbackMetadataFailureCounts[oldIdentity] = nil
        }
        if playbackMetadataTaskIdentity != nil,
           playbackMetadataTaskIdentity != newIdentity {
            cancelPlaybackMetadataRead()
        }
    }

    private func preparePlaybackMetadataSelection(for song: Song) {
        let identity = PlaybackMetadataIdentity(song)
        if currentSong.map(PlaybackMetadataIdentity.init) != identity
            || (!isPlaying && !isLoading) {
            playbackMetadataFailureCounts[identity] = nil
        }
        if playbackMetadataTaskIdentity != nil,
           playbackMetadataTaskIdentity != identity {
            cancelPlaybackMetadataRead()
        }
    }

    private func cancelPlaybackMetadataRead() {
        playbackMetadataTask?.cancel()
        playbackMetadataTask = nil
        playbackMetadataTaskIdentity = nil
        playbackMetadataTaskToken = nil
    }

    private func schedulePlaybackMetadataReadIfNeeded() {
        guard let song = currentSong,
              let service = playbackMetadataBackfill,
              let sourceType = playbackMetadataSourceType?(song.sourceID) else {
            return
        }
        let identity = PlaybackMetadataIdentity(song)
        let isAlreadyReading = playbackMetadataTaskIdentity == identity
            || service.isRereadingTags(songID: song.id)
        let hasMissingMetadata = service.needsPlaybackTagRead(
            songID: song.id,
            expectedSourceID: song.sourceID
        )
        let failedAttemptCount = playbackMetadataFailureCounts[identity] ?? 0
        guard PlaybackMetadataBackfillPolicy.shouldStart(
            sourceType: sourceType,
            hasMissingMetadata: hasMissingMetadata,
            isCueTrack: song.isCueTrack,
            isStreamDescriptor: song.isStreamDescriptor,
            isAlreadyReading: isAlreadyReading,
            completedForCurrentFile: false,
            failedAttemptCount: failedAttemptCount
        ) else {
            return
        }

        let token = UUID()
        playbackMetadataTaskIdentity = identity
        playbackMetadataTaskToken = token
        playbackMetadataTask = Task(priority: .utility) { @MainActor [weak self] in
            await self?.runPlaybackMetadataRead(
                identity: identity,
                token: token,
                service: service
            )
        }
    }

    private func runPlaybackMetadataRead(
        identity: PlaybackMetadataIdentity,
        token: UUID,
        service: MetadataBackfillService
    ) async {
        defer {
            if playbackMetadataTaskToken == token {
                playbackMetadataTask = nil
                playbackMetadataTaskIdentity = nil
                playbackMetadataTaskToken = nil
            }
        }

        while !Task.isCancelled {
            guard playbackMetadataTaskToken == token,
                  currentSong.map(PlaybackMetadataIdentity.init) == identity else {
                return
            }
            let result = await service.rereadTagsForPlayback(
                songID: identity.songID,
                expectedSourceID: identity.sourceID
            )
            guard !Task.isCancelled,
                  playbackMetadataTaskToken == token,
                  currentSong.map(PlaybackMetadataIdentity.init) == identity else {
                return
            }

            switch result {
            case .completed, .notNeeded:
                playbackMetadataFailureCounts[identity] = nil
                return
            case .alreadyReading, .unsupported, .cancelled:
                return
            case .failed:
                playbackMetadataFailureCounts[identity] =
                    PlaybackMetadataBackfillPolicy.maximumAttemptsPerPlayback
                return
            case .retryableFailure:
                guard PlaybackMetadataBackfillPolicy.shouldCountFailure(
                    isCancellation: false,
                    isTransient: true
                ) else {
                    return
                }
                let failureCount = (playbackMetadataFailureCounts[identity] ?? 0) + 1
                playbackMetadataFailureCounts[identity] = failureCount
                guard let delay = PlaybackMetadataBackfillPolicy.retryDelay(
                    afterFailedAttempt: failureCount
                ) else {
                    return
                }
                do {
                    try await Task.sleep(for: .seconds(delay))
                } catch {
                    return
                }
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
        guard appleMusic.isPlaybackStartAuthorized(requestID) else { return }
        registerPlayIntent()
        if isLiveRadio {
            stopRadioTransport(clearSelection: true)
        }
        playbackKind = .track
        appleMusicPlaybackTask?.cancel()
        appleMusicPlaybackTask = nil
        appleMusicTimeoutTask?.cancel()
        appleMusicTimeoutTask = nil
        activeAppleMusicRequestID = requestID
        // Use the Apple Music request itself as playID so every async callback,
        // mirror update and timeout has one shared generation identity.
        playID = requestID
        invalidateAutomaticAdvance(reason: "apple-music-handoff")
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
        let requestedRate = playbackSettings.outputMode == .effects
            ? playbackSettings.playbackRate
            : 1
        if isSystemAudioPlaybackActive,
           abs(requestedRate - 1) >= 0.001,
           let id = playID {
            Task { @MainActor [weak self] in
                await self?.fallbackSystemAudioToPCM(playID: id, error: nil)
            }
            return
        }
        audioEngine.applyPlaybackRate(requestedRate)
    }

    /// 如果用户启用了「输出采样率匹配」, 把 AVAudioSession 硬件 SR hint 切到
    /// 当前歌的采样率, 避免 CoreAudio 自动重采样。仅 iOS 真机生效。
    func applyOutputSampleRateMatching(for song: Song) {
        guard (playbackSettings.matchOutputSampleRate || playbackSettings.outputMode == .highFidelity),
              let sr = song.sampleRate, sr > 0 else { return }
        _ = audioEngine.prepareHardwareSampleRate(Double(sr))
    }

    func shouldApplyReplayGain(_ settings: PlaybackSettings) -> Bool {
        settings.outputMode == .effects && settings.replayGainEnabled
    }

    func shouldUseCrossfade(_ settings: PlaybackSettings) -> Bool {
        settings.outputMode == .effects && settings.crossfadeEnabled
    }

    /// Builds a direct PCM graph only from the rate reported by the active
    /// route. A preferred source rate can be rejected (Bluetooth and HDMI are
    /// common examples); labelling the graph with that rejected value renders
    /// PCM at the wrong speed and pitch.
    private func safeDirectPCMFormat(
        requestedSourceSampleRate: Double?,
        outputMode: AudioOutputMode
    ) -> AVAudioFormat? {
        guard outputMode == .highFidelity else { return nil }
        let actualRate = audioEngine.currentHardwareSampleRate
        guard let resolvedRate = DirectPCMOutputSampleRatePolicy.resolvedSampleRate(
            requestedSourceSampleRate: requestedSourceSampleRate,
            actualHardwareSampleRate: actualRate
        ) else {
            plog("ℹ️ Direct PCM route rate is unavailable; using the output node's native format")
            return nil
        }
        if let requestedSourceSampleRate,
           !DirectPCMOutputSampleRatePolicy.hardwareMatches(
            requestedSampleRate: requestedSourceSampleRate,
            actualHardwareSampleRate: actualRate
           ) {
            plog("ℹ️ Preferred PCM rate \(requestedSourceSampleRate) Hz unavailable; decoding safely at \(resolvedRate) Hz")
        }
        return audioEngine.directPCMFormat(sampleRate: resolvedRate)
    }

    /// Negotiates the render graph before decoder creation. DoP is only used
    /// when a DSP-free graph is selected and the output reports the exact DoP
    /// carrier sample rate. Unsupported routes safely fall back to PCM.
    func configureOutputPipeline(
        for song: Song,
        url: URL,
        expectedPlayID: UUID,
        reacquiringLocalRouteFocus: Bool = false
    ) async throws -> DSDPlaybackMode {
        let settings = playbackSettings.snapshot()
        let isLocalDSD = url.isFileURL && nativeDecoder.isDSD(url)
        try activateAudioSession(reacquiringLocalRouteFocus)
        // 打开 DSD 解码器要同步读文件头, 在 NAS / Files provider 上是真实
        // I/O。放到主线程外做, 回来后必须重新校验代次, 否则被顶掉的请求会
        // 继续去配置引擎。
        let probe = DSDOutputProbePolicy.required(
            isLocalDSD: isLocalDSD,
            outputModeIsHighFidelity: settings.outputMode == .highFidelity,
            dsdPlaybackModeIsPCM: settings.dsdPlaybackMode == .pcm
        )

        var dopFormat: AVAudioFormat?
        if probe == .dopThenPCM {
            dopFormat = try? await nativeDecoder.dsdOutputFormatOffMain(for: url, mode: .dop)
            // 探测是否拿到格式都已经挂起过, 被顶掉的请求不能继续往下配置。
            guard playID == expectedPlayID else { throw CancellationError() }
        }
        if let dopFormat {
            _ = audioEngine.prepareHardwareSampleRate(dopFormat.sampleRate)
            if audioEngine.hardwareSupportsDirectFormat(dopFormat) {
                try audioEngine.configure(outputMode: .highFidelity, directSourceFormat: dopFormat)
                plog("🎧 DSD output: DoP \(dopFormat.sampleRate) Hz direct")
                return .dop
            }
            plog("ℹ️ DoP carrier \(dopFormat.sampleRate) Hz unavailable; falling back to PCM")
        }

        var directPCMFormat: AVAudioFormat?
        var dsdPCMFormat: AVAudioFormat?
        if probe != .none {
            dsdPCMFormat = try? await nativeDecoder.dsdOutputFormatOffMain(for: url, mode: .pcm)
            guard playID == expectedPlayID else { throw CancellationError() }
        }
        if let pcmFormat = dsdPCMFormat {
            _ = audioEngine.prepareHardwareSampleRate(pcmFormat.sampleRate)
            directPCMFormat = safeDirectPCMFormat(
                requestedSourceSampleRate: pcmFormat.sampleRate,
                outputMode: settings.outputMode
            )
        } else {
            var sourceSampleRate = song.sampleRate.map(Double.init)
            if sourceSampleRate == nil, url.isFileURL {
                let decoder: any PrimuseAudioDecoder = await usesFFmpegDecoder(
                    for: song,
                    url: url
                ) ? ffmpegDecoder : nativeDecoder
                sourceSampleRate = try? await decoder.fileInfo(for: url).sampleRate
                guard playID == expectedPlayID else { throw CancellationError() }
            }
            if (settings.matchOutputSampleRate || settings.outputMode == .highFidelity),
               let sourceSampleRate,
               sourceSampleRate > 0 {
                _ = audioEngine.prepareHardwareSampleRate(sourceSampleRate)
            }
            directPCMFormat = safeDirectPCMFormat(
                requestedSourceSampleRate: sourceSampleRate,
                outputMode: settings.outputMode
            )
        }

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
        wasUsingDoP: Bool,
        expectedPlayID: UUID
    ) async -> AVAudioFormat? {
        guard wasUsingDoP else { return audioEngine.outputFormat }
        audioEngine.stopPlayback()
        let decodedPCMFormat = try? await nativeDecoder.dsdOutputFormatOffMain(
            for: url,
            mode: .pcm
        )
        guard playID == expectedPlayID else { return nil }
        _ = AudioSessionManager.shared.activatePlaybackSession()
        if let decodedPCMFormat {
            _ = audioEngine.prepareHardwareSampleRate(decodedPCMFormat.sampleRate)
        } else {
            applyOutputSampleRateMatching(for: song)
        }
        do {
            let directFormat = playbackSettings.outputMode == .highFidelity
                ? safeDirectPCMFormat(
                    requestedSourceSampleRate: decodedPCMFormat?.sampleRate
                        ?? song.sampleRate.map(Double.init),
                    outputMode: .highFidelity
                )
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
                if self.currentSong != nil, !self.isLoading, !self.isSystemMediaPlaybackActive {
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

        manager.onInterruptionBegan = { [weak self] interruptionTime in
            guard let self else { return }
            self.cancelAppActivationInterruptionRecovery()
            let hadPendingMusicVideo = self.pendingMusicVideoPlayID != nil
            self.pendingMusicVideoPlayID = nil
            if hadPendingMusicVideo {
                self.sourceManager?.cancelMusicVideoDownloads(keeping: nil)
            }
            let hadPendingRadioResolution = self.pendingRadioResolutionID != nil
            self.pendingRadioResolutionID = nil
            let configurationRecoveryWasActive = self.hasConfigurationRecoveryActivityEvidence
            let musicVideoSeekWasActive = self.hasMusicVideoSeekActivityEvidence
            let appleMusic = AppServices.shared.appleMusic
            let hasAppleMusicRequest = self.isAppleMusicMode
                || self.activeAppleMusicRequestID != nil
                || appleMusic.activePlaybackRequestID != nil
            guard self.currentSong != nil
                    || hasAppleMusicRequest
                    || hadPendingRadioResolution else { return }
            // A configuration notification can precede the interruption. Cancel
            // its speculative recovery before reading/publishing any paused state;
            // only the interruption lifecycle may authorize a resume now.
            self.cancelPendingConfigurationRecovery()
            let pendingAppleMusicRequestID = self.activeAppleMusicRequestID
                ?? appleMusic.activePlaybackRequestID
            if let pendingAppleMusicRequestID,
               appleMusic.playbackPhase(for: pendingAppleMusicRequestID) == .pending {
                // This request never produced audio. In particular, currentSong
                // may still describe the previous local item while an ownership
                // handoff is awaiting a renderer. Cancel the pending generation
                // instead of minting a resume ticket for that stale visible item.
                self.appleMusicPlaybackTask?.cancel()
                self.appleMusicPlaybackTask = nil
                self.appleMusicTimeoutTask?.cancel()
                self.appleMusicTimeoutTask = nil
                appleMusic.cancelPlaybackRequest(pendingAppleMusicRequestID)
                if self.activeAppleMusicRequestID == pendingAppleMusicRequestID {
                    self.activeAppleMusicRequestID = nil
                }
                self.invalidateAutomaticAdvance(reason: "interruption-pending-apple-music")
                self.stopTimeUpdater()
                self.audioEngine.suspendPlaybackClockReads()
                self.isLoading = false
                self.isPlaying = false
                self.updateNowPlayingInfo()
                self.updatePlaybackState()
                return
            }
            if AppleMusicAudioSessionInterruptionPolicy.shouldDeferToSystemTransport(
                hasActivePlaybackRequest: hasAppleMusicRequest,
                requestIsPending: false
            ) {
                // ApplicationMusicPlayer takes over the route after Primuse's
                // local engine yields. That handoff interrupts our dormant
                // AVAudioSession even though MusicKit is already playing. Keep
                // MusicKit authoritative so the handoff cannot clear queue
                // intent or strand a mixed-source queue in a paused state.
                // Genuine calls/route interruptions are mirrored by MusicKit;
                // its end watchdog remains suppressed until its clock advances.
                appleMusic.markPlaybackInterrupted()
                plog("🔇 Active Apple Music interruption delegated to MusicKit")
                return
            }
            // A cold catalog request may not have mirrored currentSong yet.
            // It was never actually playing, so the interruption only cancels
            // its pending start; it must not create an automatic resume ticket.
            guard self.currentSong != nil else {
                self.isLoading = false
                self.isPlaying = false
                self.stopTimeUpdater()
                self.updateNowPlayingInfo()
                self.updatePlaybackState()
                return
            }
            // Casting owns playback on another device and is not interrupted by
            // this phone's AVAudioSession. Its polling remains authoritative.
            guard !self.isCastingMode else { return }
            // The engine may already be stopped by the time AVAudioSession
            // delivers `.began`. Use the last state that was published after
            // validating the real backend output, never the raw mirrored flag.
            let wasPlaying = self.lastPublishedPlaybackWasActive
                || configurationRecoveryWasActive
                || musicVideoSeekWasActive
            let wasAwaitingInterruptionEnd = self.interruptionResumePolicy
                .isAwaitingInterruptionEnd
            self.interruptionResumePolicy.interruptionBegan(
                wasActuallyPlaying: wasPlaying,
                currentItemID: self.currentSong?.id
            )
            self.configurationRecoveryActivityEvidence = nil
            self.musicVideoSeekActivityEvidence = nil
            let preservedExistingTicket = wasAwaitingInterruptionEnd
                && !wasPlaying
                && self.interruptionResumePolicy.isAwaitingInterruptionEnd
            let frozenProgress = self.interpolatedTime(at: interruptionTime)
            self.stopTimeUpdater()
            self.audioEngine.suspendPlaybackClockReads()
            if self.isSystemMediaPlaybackActive {
                self.activeSystemMediaPlayer?.pause()
                self.removeMusicVideoObservers()
            }
            self.invalidateAutomaticAdvance(reason: "interruption-began")
            // Once a fade has committed, currentSong already points at the
            // incoming track while the engine's primary node still belongs to
            // the outgoing one. The cached visible clock already belongs to the
            // incoming song, so finish the node swap without querying a graph
            // that AVFAudio may have stopped before delivering this callback.
            self.cancelCrossfadeAttempt(
                finishingCommittedTransition: true,
                completionMode: .preserveCachedProgress
            )
            if !preservedExistingTicket {
                self.currentTime = frozenProgress
                self.pendingRecoveryTime = frozenProgress
            }
            self.needsPlaybackRecovery = self.needsPlaybackRecovery || wasPlaying
            if self.isLiveRadio {
                // A delayed reconnect is an internal recovery attempt, not a
                // user Play. Quiesce every radio backend and give authorized
                // interruption end a fresh playID to rebuild the same station.
                self.playID = UUID()
                self.radioReconnectTask?.cancel()
                self.radioReconnectTask = nil
                self.radioPlaybackController.stop()
                self.radioLiveStreamSource?.cancel()
                self.radioLiveStreamSource = nil
                self.decodingTask?.cancel()
                self.decodingTask = nil
                self.audioEngine.stopPlayback()
                self.hasPreparedLocalPlayback = false
                self.isLoading = false
            }
            if !self.isAppleMusicMode, !self.isLiveRadio {
                // An in-flight local/MV rebuild must not swallow the one-shot
                // authorized interruption end behind the generic isLoading
                // resume guard. Its stale task is already disqualified above.
                self.isLoading = false
            }

            if preservedExistingTicket {
                self.scheduleAppActivationInterruptionRecovery()
            }

            // Sync UI to paused state — the engine was already stopped by the system.
            self.isPlaying = false
            self.updateNowPlayingInfo()
            self.updatePlaybackState()
        }

        manager.onInterruptionEnded = { [weak self] systemShouldResume in
            guard let self else { return }
            self.cancelAppActivationInterruptionRecovery()
            let shouldResume = self.interruptionResumePolicy.interruptionEnded(
                systemShouldResume: systemShouldResume,
                currentItemID: self.currentSong?.id
            )
            guard shouldResume else {
                self.updateNowPlayingInfo()
                self.updatePlaybackState()
                return
            }
            self.resumeAfterAuthorizedInterruption(source: "system-ended")
        }

        manager.onConfigurationChange = { [weak self] configurationChangeTime in
            guard let self, self.currentSong != nil else { return }
            let appleMusic = AppServices.shared.appleMusic
            // MusicKit, radio, casting, and AVPlayer own their route recovery.
            // Restarting the dormant local engine here would overwrite their
            // visible playing state after an otherwise successful route change.
            guard !self.isAppleMusicMode,
                  self.activeAppleMusicRequestID == nil,
                  appleMusic.activePlaybackRequestID == nil,
                  !self.isLiveRadio,
                  !self.isCastingMode,
                  (self.pendingMusicVideoPlayID == nil
                    || self.pendingMusicVideoPlayID != self.playID),
                  !self.isSystemMediaPlaybackActive else { return }
            if self.localRouteFocusRecoveryOwnerPlayID == self.playID {
                if AudioSessionManager.shared.outputRouteIsBuiltIn {
                    plog("🔧 Audio engine configuration change absorbed by local route focus recovery")
                    return
                }
                // The route changed again before recovery completed. Let the
                // ordinary configuration pipeline rebuild for the new output.
                self.localRouteFocusRecoveryOwnerPlayID = nil
            }
            // The graph rebuild below can itself enqueue a configuration
            // notification. Suppress only that explicitly-owned rebuild,
            // never every notification that happens to arrive while loading.
            if self.configurationRecoveryOwnerPlayID == self.playID {
                // Consume exactly one notification emitted by our own graph
                // rebuild. A second notification may be a real route/config
                // change and must invalidate the replacement pipeline.
                self.configurationRecoveryOwnerPlayID = nil
                plog("🔧 Audio engine configuration change absorbed by active configuration recovery")
                return
            }
            self.audioEngine.markHardwareConfigurationChanged()
            let carriedConfigurationActivity = self.hasConfigurationRecoveryActivityEvidence
            let shouldAutoResume = (
                self.isPlaying || self.isLoading || carriedConfigurationActivity
            )
                && self.interruptionResumePolicy.playbackIsIntended
            let interruptedActivityWasPublished = self.lastPublishedPlaybackWasActive
                || carriedConfigurationActivity
            let frozenProgress = self.interpolatedTime(at: configurationChangeTime)
            self.stopTimeUpdater()
            self.audioEngine.suspendPlaybackClockReads()
            self.invalidateAutomaticAdvance(reason: "engine-configuration-change")
            self.cancelCrossfadeAttempt(
                finishingCommittedTransition: true,
                completionMode: .preserveCachedProgress
            )
            self.currentTime = frozenProgress
            self.pendingRecoveryTime = frozenProgress
            self.needsPlaybackRecovery = self.hasPreparedLocalPlayback
                || self.needsPlaybackRecovery
                || shouldAutoResume
            self.isPlaying = false
            self.updateNowPlayingInfo()
            self.updatePlaybackState()

            guard shouldAutoResume, let songID = self.currentSong?.id else {
                self.configurationRecoveryActivityEvidence = nil
                return
            }
            if interruptedActivityWasPublished {
                self.configurationRecoveryActivityEvidence = .init(
                    itemID: songID,
                    rebuildPlayID: nil
                )
            } else {
                self.configurationRecoveryActivityEvidence = nil
            }
            // Configuration and interruption notifications use different queues;
            // Apple does not guarantee their order. Do not reactivate the
            // nonmixable playback session from this callback. Preserve the last
            // published active snapshot for a possible interruption-began ticket,
            // then allow a short settle window. A real interruption cancels this
            // candidate and becomes the sole resume authority.
            self.lastPublishedPlaybackWasActive = interruptedActivityWasPublished
            self.scheduleConfigurationRecovery(for: songID)
        }
    }

    private func scheduleConfigurationRecovery(for songID: String, attempt: Int = 0) {
        configurationRecoveryTask?.cancel()
        configurationRecoveryPendingSongID = songID
        configurationRecoveryTask = Task { @MainActor [weak self] in
            do {
                // Give interruptionNotification (main queue) or a route-loss
                // notification time to overtake the engine's internal callback.
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                return
            }
            guard let self,
                  self.configurationRecoveryPendingSongID == songID else { return }
            self.configurationRecoveryTask = nil
            if self.attemptPendingConfigurationRecovery() { return }
            // Still blocked (typically HFP is not released yet). A route change
            // normally wakes this candidate, but iOS does not guarantee one, so
            // re-arm a bounded number of times instead of hanging forever.
            guard self.configurationRecoveryPendingSongID == songID,
                  attempt < 8 else {
                self.cancelPendingConfigurationRecovery()
                self.configurationRecoveryActivityEvidence = nil
                return
            }
            self.scheduleConfigurationRecovery(for: songID, attempt: attempt + 1)
        }
    }

    @discardableResult
    private func attemptPendingConfigurationRecovery() -> Bool {
        guard let songID = configurationRecoveryPendingSongID else { return false }
        guard interruptionResumePolicy.playbackIsIntended,
              currentSong?.id == songID else {
            cancelPendingConfigurationRecovery()
            configurationRecoveryActivityEvidence = nil
            return false
        }
        guard !interruptionResumePolicy.isAwaitingInterruptionEnd,
              !isPlaybackActuallyActive,
              !AudioSessionManager.shared.outputRouteIsBluetoothHFP else {
            return false
        }
        cancelPendingConfigurationRecovery()
        seek(
            to: pendingRecoveryTime,
            startPlaying: true,
            isRecovery: true,
            isConfigurationRecovery: true
        )
        return true
    }

    #if os(iOS)
    private func observeCarAudioRouteState() {
        guard carPlayConnectObserver == nil else { return }
        // A restored player may publish metadata before didConnect reaches its
        // observer. Give CarPlay a stable title in that first snapshot as well.
        isCarPlaySceneActive = UIApplication.shared.connectedScenes.contains {
            $0 is CPTemplateApplicationScene && $0.activationState != .unattached
        }
        // currentRoute performs synchronous IPC; lyric ticks only need the
        // latest route snapshot, which route-change notifications keep current.
        isCarAudioRouteConnected = Self.isCarAudioRouteActive()
        let center = NotificationCenter.default

        carPlayConnectObserver = center.addObserver(
            forName: .primuseCarPlaySceneDidConnect,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isCarPlaySceneActive = true
                self.publishLockScreenLyricsIfNeeded()
                self.forceAudioOnlyIfNeeded()
            }
        }

        carPlayDisconnectObserver = center.addObserver(
            forName: .primuseCarPlaySceneDidDisconnect,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isCarPlaySceneActive = false
                self.publishLockScreenLyricsIfNeeded()
            }
        }

        carAudioRouteObserver = center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in
            // userInfo 不是 Sendable, 在 hop 出去之前先取出原始值和旧路由
            // 的 Sendable port-type 快照。当前路由在主 actor 上现取, 避免把
            // AVAudioSessionRouteDescription 捕获进 Task。
            let reasonValue = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            let previousOutputs = (
                note.userInfo?[AVAudioSessionRouteChangePreviousRouteKey]
                    as? AVAudioSessionRouteDescription
            )?.outputs ?? []
            let previousRouteWasAirPlay = previousOutputs.contains { $0.portType == .airPlay }
            let previousRouteHadExternalOutput = previousOutputs.contains {
                $0.portType != .builtInSpeaker && $0.portType != .builtInReceiver
            }
            let currentOutputs = AVAudioSession.sharedInstance().currentRoute.outputs
            let previousOutputTypes = previousOutputs.map { $0.portType.rawValue }.joined(separator: ",")
            let currentOutputTypes = currentOutputs.map { $0.portType.rawValue }.joined(separator: ",")
            let previousOutputUIDs = Set(previousOutputs.map(\.uid).filter { !$0.isEmpty })
            let hasSameOutputDevice = currentOutputs.contains { previousOutputUIDs.contains($0.uid) }
            let routeChangeTime = Date()
            Task { @MainActor [weak self] in
                guard let self else { return }
                let reason = reasonValue.flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
                let session = AVAudioSession.sharedInstance()
                let handlingOutputs = session.currentRoute.outputs
                self.isCarAudioRouteConnected = handlingOutputs.contains { $0.portType == .carAudio }
                self.publishLockScreenLyricsIfNeeded()
                let handlingOutputTypes = handlingOutputs
                    .map { $0.portType.rawValue }
                    .joined(separator: ",")
                let handlingRouteHasExternalOutput = handlingOutputs.contains {
                    $0.portType != .builtInSpeaker && $0.portType != .builtInReceiver
                }
                let handlingRouteIsBuiltIn = handlingOutputs.contains {
                    $0.portType == .builtInSpeaker || $0.portType == .builtInReceiver
                }
                plog("🔀 Audio route changed reason=\(String(describing: reason)) raw=\(reasonValue.map(String.init) ?? "nil") previous=[\(previousOutputTypes)] observed=[\(currentOutputTypes)] handling=[\(handlingOutputTypes)] sameOutputDevice=\(hasSameOutputDevice) song=\(self.currentSong?.id ?? "nil") time=\(String(format: "%.3f", self.currentTime)) playing=\(self.isPlaying) loading=\(self.isLoading) intended=\(self.interruptionResumePolicy.playbackIsIntended) awaitingInterruptionEnd=\(self.interruptionResumePolicy.isAwaitingInterruptionEnd) otherAudio=\(session.isOtherAudioPlaying)")
                let reasonIsOldDeviceUnavailable = reason == .oldDeviceUnavailable
                if self.recoverLocalAudioFocusAfterAirPlayReturn(
                    previousRouteWasAirPlay: previousRouteWasAirPlay,
                    currentRouteIsBuiltIn: handlingRouteIsBuiltIn,
                    reasonIsOldDeviceUnavailable: reasonIsOldDeviceUnavailable,
                    at: routeChangeTime
                ) {
                    self.forceAudioOnlyIfNeeded()
                    return
                }
                if AudioOutputRouteLossPolicy.shouldPause(
                    reasonIsOldDeviceUnavailable: reasonIsOldDeviceUnavailable,
                    previousRouteHadExternalOutput: previousRouteHadExternalOutput,
                    currentRouteHasExternalOutput: handlingRouteHasExternalOutput
                ) {
                    // Keep the user's audio private only for a real external
                    // route fallback. Built-in speaker churn and transitions
                    // between external outputs leave playback untouched.
                    self.handleOutputDeviceDisappeared()
                    return
                }
                // HFP → A2DP 的切回不保证再发一次引擎配置变更(挂起时引擎
                // 已停), route change 同时唤醒“已获系统授权”和“纯配置
                // 变化”两类候选; 前者优先, 且二者互不冒充恢复授权。
                if !self.attemptBluetoothHFPDeferredResume() {
                    self.attemptPendingConfigurationRecovery()
                }
                self.forceAudioOnlyIfNeeded()
            }
        }
    }

    /// An active long-form session stays active while its output moves from
    /// AirPlay back to the phone. Because activation did not change, iOS does
    /// not run non-mixable focus arbitration again and another app that was
    /// using the built-in output can remain audible. Rebuild the local graph
    /// at the same position and explicitly reacquire the session once the
    /// complete engine has stopped.
    @discardableResult
    private func recoverLocalAudioFocusAfterAirPlayReturn(
        previousRouteWasAirPlay: Bool,
        currentRouteIsBuiltIn: Bool,
        reasonIsOldDeviceUnavailable: Bool,
        at routeChangeTime: Date
    ) -> Bool {
        guard let song = currentSong else { return false }
        let appleMusic = AppServices.shared.appleMusic
        let supportsLocalPipelineRecovery = !isAppleMusicMode
            && activeAppleMusicRequestID == nil
            && appleMusic.activePlaybackRequestID == nil
            && !isLiveRadio
            && !isCastingMode
            && (pendingMusicVideoPlayID == nil || pendingMusicVideoPlayID != playID)
            && !isSystemMediaPlaybackActive
        let playbackWasActive = isPlaybackActuallyActive
            || lastPublishedPlaybackWasActive
            || hasConfigurationRecoveryActivityEvidence

        guard AirPlayReturnFocusRecoveryPolicy.shouldReacquire(
            previousRouteWasAirPlay: previousRouteWasAirPlay,
            currentRouteIsBuiltIn: currentRouteIsBuiltIn,
            reasonIsOldDeviceUnavailable: reasonIsOldDeviceUnavailable,
            playbackWasActive: playbackWasActive,
            playbackIsIntended: interruptionResumePolicy.playbackIsIntended,
            isAwaitingInterruptionEnd: interruptionResumePolicy.isAwaitingInterruptionEnd,
            supportsLocalPipelineRecovery: supportsLocalPipelineRecovery
        ) else { return false }

        let frozenProgress = configurationRecoveryPendingSongID == song.id
            ? pendingRecoveryTime
            : interpolatedTime(at: routeChangeTime)
        cancelPendingConfigurationRecovery()
        configurationRecoveryActivityEvidence = .init(
            itemID: song.id,
            rebuildPlayID: nil
        )
        pendingRecoveryTime = frozenProgress
        needsPlaybackRecovery = true
        plog("📱 AirPlay returned to built-in output — reacquiring local playback focus")
        seek(
            to: frozenProgress,
            startPlaying: true,
            isRecovery: true,
            isConfigurationRecovery: true,
            reacquiringLocalRouteFocus: true
        )
        return true
    }

    /// 输出设备消失 —— 车机熄火 / 拔耳机 / 蓝牙断开都归这一类。
    ///
    /// 系统此时会把路由切到内置扬声器并继续播放, 于是音乐突然从手机公放出来。
    /// Apple 对这个 reason 的既定做法就是暂停: 用户拔掉设备的动作本身就表示
    /// "我不想再听了", 而不是"请换个喇叭接着放"。
    ///
    /// 用 `pause()` 而不是 `stop()` —— 保留曲目和进度, 重新插上耳机 / 上车后
    /// 用户按播放就能接着听。
    private func handleOutputDeviceDisappeared() {
        // A cold radio request has not installed currentSong yet. Cancel its
        // resolver before any early return so it cannot start on the phone
        // speaker after the selected output disappears.
        pendingRadioResolutionID = nil
        cancelPendingConfigurationRecovery()
        clearBluetoothHFPDeferredResume()
        // A local AVAudioSession route change does not describe the renderer
        // that owns a cast session, so it must not pause remote playback.
        guard !isCastingMode else {
            plog("🔌 Local output disappeared while casting — remote transport unchanged")
            return
        }
        let appleMusic = AppServices.shared.appleMusic
        let hasAppleMusicRequest = activeAppleMusicRequestID != nil
            || appleMusic.activePlaybackRequestID != nil
        guard currentSong != nil || hasAppleMusicRequest,
              hasAppleMusicRequest
                || isPlaying
                || isLoading
                || interruptionResumePolicy.playbackIsIntended else { return }
        plog("🔌 Output device disappeared (CarPlay/headphones/BT) — pausing instead of falling back to the speaker")
        pause()
    }

    private func forceAudioOnlyIfNeeded() {
        guard shouldForceAudioOnly,
              isMusicVideoPlaybackActive,
              isPlaying || isLoading else { return }
        Task { await replayCurrentSongAsAudio(restoreMusicVideoModeAfterPlay: true) }
    }
    #endif

    func clearPendingPlaybackRecovery() {
        needsPlaybackRecovery = false
        pendingRecoveryTime = 0
        pendingRecoveryIsColdSessionRestore = false
        clearBluetoothHFPDeferredResume()
    }

    private func resumeAfterAuthorizedInterruption(source: String) {
        guard !isPlaybackActuallyActive, currentSong != nil else {
            updateNowPlayingInfo()
            updatePlaybackState()
            return
        }
        // The interruption may end before the recording app releases HFP.
        // Reactivating our nonmixable playback session here would interrupt
        // that app again. Keep the one-shot resume bound to this item until a
        // later route change confirms that Bluetooth is back on A2DP.
        if AudioSessionManager.shared.outputRouteIsBluetoothHFP {
            bluetoothHFPSuspendedSongID = currentSong?.id
            scheduleBluetoothHFPResumeWatchdog()
            updateNowPlayingInfo()
            updatePlaybackState()
            return
        }
        plog("🔊 Resuming authorized interruption source=\(source)")
        resumeCurrentPlayback(registeringUserIntent: false)
    }

    @discardableResult
    private func attemptAppActivationInterruptionRecovery() -> Bool {
        let shouldResume = interruptionResumePolicy.resumeAfterAppActivationIfSafe(
            otherAudioIsPlaying: AudioSessionManager.shared.otherAudioIsPlaying,
            currentItemID: currentSong?.id
        )
        guard shouldResume else { return false }
        resumeAfterAuthorizedInterruption(source: "app-activation")
        return true
    }

    /// Scene activation can overtake the final audio-session notification when
    /// another app is being backgrounded. Allow that state to settle briefly;
    /// the ticket remains pending after the bounded retries and can still be
    /// consumed by a later genuine interruption-end notification.
    func scheduleAppActivationInterruptionRecovery(attempt: Int = 0) {
        cancelAppActivationInterruptionRecovery()
        guard interruptionResumePolicy.isAwaitingInterruptionEnd,
              attempt < Self.appActivationInterruptionRecoveryAttemptLimit else { return }
        appActivationInterruptionRecoveryTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                return
            }
            guard let self else { return }
            self.appActivationInterruptionRecoveryTask = nil
            if self.attemptAppActivationInterruptionRecovery() { return }
            guard self.interruptionResumePolicy.isAwaitingInterruptionEnd else { return }
            self.scheduleAppActivationInterruptionRecovery(attempt: attempt + 1)
        }
    }

    func cancelAppActivationInterruptionRecovery() {
        appActivationInterruptionRecoveryTask?.cancel()
        appActivationInterruptionRecoveryTask = nil
    }

    /// HFP 抢占结束(对方录音结束, 蓝牙回到 A2DP)后续播挂起的播放。
    /// 挂起票据一次性消费; 恢复只在用户播放意图未变、没有待决系统中断、
    /// 且输出仍在蓝牙上时发生 —— 蓝牙在挂起期间断开的话, 票据作废,
    /// 绝不落到扬声器外放。返回 true 表示本次通知已被恢复动作消费。
    @discardableResult
    private func attemptBluetoothHFPDeferredResume() -> Bool {
        let decision = BluetoothPlaybackRecoveryPolicy.deferredResumeDecision(
            hasTicket: bluetoothHFPSuspendedSongID != nil,
            currentRouteIsBluetoothHFP: AudioSessionManager.shared.outputRouteIsBluetoothHFP,
            currentRouteIsBluetooth: AudioSessionManager.shared.outputRouteIsBluetooth,
            playbackIsIntended: interruptionResumePolicy.playbackIsIntended,
            isAwaitingInterruptionEnd: interruptionResumePolicy.isAwaitingInterruptionEnd,
            isPlaybackActuallyActive: isPlaybackActuallyActive,
            suspendedItemMatchesCurrent: bluetoothHFPSuspendedSongID == currentSong?.id,
            supportsAutomaticRecovery: !isCastingMode
        )
        switch decision {
        case .wait:
            return false
        case .discard:
            clearBluetoothHFPDeferredResume()
            return false
        case .resume:
            clearBluetoothHFPDeferredResume()
            plog("🎧 Bluetooth HFP preemption ended — resuming authorized playback")
            if !isAppleMusicMode,
               !isLiveRadio,
               !isSystemMediaPlaybackActive {
                seek(
                    to: pendingRecoveryTime,
                    startPlaying: true,
                    isRecovery: true,
                    isConfigurationRecovery: true
                )
            } else {
                resumeCurrentPlayback(registeringUserIntent: false)
            }
            return true
        }
    }

    /// A route change normally wakes the authorized HFP ticket, but iOS does not
    /// guarantee one after the recording app releases the profile. Poll a bounded
    /// number of times so an authorized resume cannot hang indefinitely.
    private func scheduleBluetoothHFPResumeWatchdog(attempt: Int = 0) {
        bluetoothHFPResumeWatchdogTask?.cancel()
        guard let songID = bluetoothHFPSuspendedSongID, attempt < 20 else {
            bluetoothHFPResumeWatchdogTask = nil
            return
        }
        bluetoothHFPResumeWatchdogTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(500))
            } catch {
                return
            }
            guard let self,
                  self.bluetoothHFPSuspendedSongID == songID else { return }
            self.bluetoothHFPResumeWatchdogTask = nil
            if self.attemptBluetoothHFPDeferredResume() { return }
            guard self.bluetoothHFPSuspendedSongID == songID else { return }
            self.scheduleBluetoothHFPResumeWatchdog(attempt: attempt + 1)
        }
    }

    private func clearBluetoothHFPDeferredResume() {
        bluetoothHFPSuspendedSongID = nil
        bluetoothHFPResumeWatchdogTask?.cancel()
        bluetoothHFPResumeWatchdogTask = nil
    }

    private func cancelPendingConfigurationRecovery() {
        configurationRecoveryTask?.cancel()
        configurationRecoveryTask = nil
        configurationRecoveryPendingSongID = nil
    }

    var hasConfigurationRecoveryActivityEvidence: Bool {
        guard let evidence = configurationRecoveryActivityEvidence,
              evidence.itemID == currentSong?.id else { return false }
        return evidence.rebuildPlayID.map { $0 == playID } ?? true
    }

    var hasMusicVideoSeekActivityEvidence: Bool {
        guard let evidence = musicVideoSeekActivityEvidence else { return false }
        return evidence.itemID == currentSong?.id
            && evidence.playID == playID
            && evidence.observerGeneration == musicVideoObserverGeneration
            && isSystemMediaPlaybackActive
    }

    func registerPlayIntent() {
        pendingRadioResolutionID = nil
        playbackSessionRestoreLifecycle.supersedeForPlaybackIntent()
        cancelAppActivationInterruptionRecovery()
        cancelPendingConfigurationRecovery()
        configurationRecoveryActivityEvidence = nil
        musicVideoSeekActivityEvidence = nil
        pendingSystemAudioSeek = nil
        pendingMusicVideoPlayID = nil
        clearBluetoothHFPDeferredResume()
        interruptionResumePolicy.registerPlayIntent()
        castingCommandGeneration &+= 1
    }

    func registerPauseOrStopIntent() {
        pendingRadioResolutionID = nil
        playbackSessionRestoreLifecycle.completeForPauseOrStopIntent()
        cancelAppActivationInterruptionRecovery()
        cancelPendingConfigurationRecovery()
        configurationRecoveryActivityEvidence = nil
        musicVideoSeekActivityEvidence = nil
        pendingSystemAudioSeek = nil
        pendingMusicVideoPlayID = nil
        clearBluetoothHFPDeferredResume()
        interruptionResumePolicy.registerPauseOrStopIntent()
        castingCommandGeneration &+= 1
        invalidateAutomaticAdvance(reason: "pause-or-stop")
        let appleMusic = AppServices.shared.appleMusic
        if activeAppleMusicRequestID != nil || appleMusic.activePlaybackRequestID != nil {
            _ = appleMusic.pauseAppleMusic()
        }
    }

    func invalidateInterruptionResumePreservingIntent() {
        cancelAppActivationInterruptionRecovery()
        configurationRecoveryActivityEvidence = nil
        musicVideoSeekActivityEvidence = nil
        pendingMusicVideoPlayID = nil
        interruptionResumePolicy.invalidatePendingResumePreservingIntent()
    }

    @discardableResult
    func beginAutomaticAdvanceTransport(
        itemID: String,
        reason: String
    ) -> PlaybackAdvanceTicket {
        let ticket = playbackAdvancePolicy.beginTransport(itemID: itemID)
        localPipelineAdvanceTicket = ticket
        plog("🎫 auto-advance transport began reason=\(reason) generation=\(ticket.generation) ticket=\(ticket.id.uuidString.prefix(8))")
        return ticket
    }

    func invalidateAutomaticAdvance(reason: String) {
        let oldGeneration = playbackAdvancePolicy.generation
        playbackAdvancePolicy.invalidate()
        plog("🚫 auto-advance invalidated reason=\(reason) generation=\(oldGeneration)->\(playbackAdvancePolicy.generation)")
    }

    func preparedAutomaticAdvanceTicket(itemID: String) -> PlaybackAdvanceTicket? {
        playbackAdvancePolicy.prepareSuccessor(itemID: itemID)
    }

    func automaticAdvanceDecision(
        for ticket: PlaybackAdvanceTicket,
        trigger: String,
        consume: Bool,
        transportIsActive explicitTransportIsActive: Bool? = nil
    ) -> PlaybackAdvanceDecision {
        let intended = interruptionResumePolicy.playbackIsIntended
        let transportIsActive = explicitTransportIsActive
            ?? (isPlaying && audioEngine.isActuallyPlaying)
        let decision: PlaybackAdvanceDecision
        if consume {
            decision = playbackAdvancePolicy.consume(
                ticket,
                currentItemID: currentSong?.id,
                playbackIsIntended: intended,
                transportIsActive: transportIsActive
            )
        } else {
            decision = playbackAdvancePolicy.decision(
                for: ticket,
                currentItemID: currentSong?.id,
                playbackIsIntended: intended,
                transportIsActive: transportIsActive
            )
        }
        if decision == .accepted {
            plog("✅ auto-advance accepted trigger=\(trigger) generation=\(ticket.generation) ticket=\(ticket.id.uuidString.prefix(8))")
        } else {
            plog("🛡️ dropped stale playback completion trigger=\(trigger) reason=\(decision.rawValue) ticketGeneration=\(ticket.generation) activeGeneration=\(playbackAdvancePolicy.generation)")
        }
        return decision
    }

    func isLocalTransportStartAuthorized(
        playID id: UUID,
        itemID: String,
        trigger: String,
        expectedTicket: PlaybackAdvanceTicket? = nil
    ) -> Bool {
        guard playID == id,
              let ticket = playbackAdvancePolicy.activeTicket,
              ticket.itemID == itemID,
              expectedTicket.map({ $0 == ticket }) ?? true else {
            plog("🛡️ prevented local transport start trigger=\(trigger) reason=stale-transport")
            return false
        }
        let decision = playbackAdvancePolicy.decision(
            for: ticket,
            currentItemID: currentSong?.id,
            playbackIsIntended: interruptionResumePolicy.playbackIsIntended,
            // This is a pre-start identity/intent check. A render node cannot
            // be active until after this decision authorizes play().
            transportIsActive: true
        )
        guard decision == .accepted else {
            plog("🛡️ prevented local transport start trigger=\(trigger) reason=\(decision.rawValue) generation=\(ticket.generation)")
            return false
        }
        return true
    }

    /// Validates an explicitly selected transport while its async ownership
    /// handoff is still in flight and before currentSong is installed.
    func isPendingTransportStartAuthorized(
        playID id: UUID,
        itemID: String,
        trigger: String,
        expectedTicket: PlaybackAdvanceTicket
    ) -> Bool {
        guard playID == id,
              playbackAdvancePolicy.activeTicket == expectedTicket else {
            plog("🛡️ prevented pending transport start trigger=\(trigger) reason=stale-transport")
            return false
        }
        let decision = playbackAdvancePolicy.decision(
            for: expectedTicket,
            currentItemID: itemID,
            playbackIsIntended: interruptionResumePolicy.playbackIsIntended,
            transportIsActive: true
        )
        guard decision == .accepted else {
            plog("🛡️ prevented pending transport start trigger=\(trigger) reason=\(decision.rawValue) generation=\(expectedTicket.generation)")
            return false
        }
        return true
    }

    func syncPlaybackProgressFromEngine() {
        if isSystemMediaPlaybackActive {
            let seconds = activeSystemMediaPlayer?.currentTime().seconds ?? currentTime
            guard seconds.isFinite else { return }
            currentTime = max(0, seconds)
            return
        }
        guard !isAppleMusicMode, !isLiveRadio, !isCastingMode else { return }
        let decision = localPlaybackClockDecision(isTransitioning: isCrossfading)
        guard let engineTime = decision.visibleTime else { return }
        currentTime = max(0, engineTime)
    }

    func localPlaybackClockDecision(
        isTransitioning: Bool
    ) -> CrossfadePlaybackClockDecision {
        let primaryNodeTime: TimeInterval?
        let incomingNodeTime: TimeInterval?
        switch PlaybackClockReadPolicy.target(isTransitioning: isTransitioning) {
        case .primary:
            primaryNodeTime = audioEngine.currentTime
            incomingNodeTime = nil
        case .incoming:
            primaryNodeTime = nil
            incomingNodeTime = audioEngine.crossfadeCurrentTime
        }
        return CrossfadePlaybackClockPolicy.decision(
            currentTime: currentTime,
            primaryNodeTime: primaryNodeTime,
            incomingNodeTime: incomingNodeTime,
            isTransitioning: isTransitioning
        )
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

        if !shouldPlay {
            // A mode preference change while paused is not a Play command.
            // Disabling an active MV stages same-position audio recovery;
            // enabling MV is applied by the next explicit resume.
            if isMusicVideoPlaybackActive, !enabled {
                await replayCurrentSongAsAudio(restoreMusicVideoModeAfterPlay: false)
            } else {
                updateNowPlayingInfo()
                updatePlaybackState()
            }
            return
        }

        await play(song: song)
        if resumeTime > 0 {
            await waitForPlaybackPipelineSettled()
            seek(to: resumeTime, startPlaying: shouldPlay)
        }
    }

    private func replayCurrentSongAsAudio(restoreMusicVideoModeAfterPlay: Bool) async {
        guard let song = currentSong else { return }
        let resumeTime = currentTime
        let shouldPlay = isPlaying || isLoading
        let previousMode = isMusicVideoModeEnabled

        isMusicVideoModeEnabled = false
        if !shouldPlay {
            registerPauseOrStopIntent()
            stopMusicVideoPlayback(clearPlayer: true)
            decodingTask?.cancel()
            decodingTask = nil
            audioEngine.stopPlayback()
            hasPreparedLocalPlayback = false
            currentSong = song
            currentTime = resumeTime
            pendingRecoveryTime = resumeTime
            needsPlaybackRecovery = true
            isLoading = false
            isPlaying = false
            isAtTrackEnd = false
            if restoreMusicVideoModeAfterPlay {
                isMusicVideoModeEnabled = previousMode
            }
            updateNowPlayingInfo()
            updatePlaybackState()
            return
        }
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

    private func preferredSystemAudioProfile(
        for song: Song,
        url: URL
    ) async -> ISOBaseMediaAudioProfile? {
        guard song.cueStartTime == nil,
              song.cueEndTime == nil,
              [.m4a, .mp4, .alac].contains(song.fileFormat),
              !SourceManager.isTranscodedStreamURL(url),
              song.fileSize > 0 else { return nil }

        let profile: ISOBaseMediaAudioProfile?
        if url.isFileURL {
            profile = await Task.detached(priority: .userInitiated) {
                Self.readPreferredSystemAudioProfile(
                    from: url,
                    fileSize: song.fileSize
                )
            }.value
        } else if sourceManager != nil || isDLNACast(song) {
            do {
                var head = Data()
                for probeSize in RemoteMetadataReadPolicy.containerTailReadSizes(
                    fileSize: song.fileSize
                ) {
                    let desiredHeadSize = min(Int64(probeSize), song.fileSize)
                    if Int64(head.count) < desiredHeadSize {
                        let newBytes = try await fetchSystemAudioMetadataRange(
                            for: song,
                            url: url,
                            offset: Int64(head.count),
                            length: desiredHeadSize - Int64(head.count)
                        )
                        guard !newBytes.isEmpty else { break }
                        head.append(newBytes)
                    }

                    var profiles = ISOBaseMediaAudioProfileParser.parse(head: head)
                    if profiles.isEmpty, Int64(probeSize) < song.fileSize {
                        do {
                            let tail = try await fetchSystemAudioMetadataRange(
                                for: song,
                                url: url,
                                offset: -Int64(probeSize),
                                length: Int64(probeSize)
                            )
                            profiles = ISOBaseMediaAudioProfileParser.parse(head: head, tail: tail)
                        } catch MetadataRangeReadError.suffixRangeUnsupported {
                            // Some DLNA endpoints ignore suffix ranges. Keep
                            // growing the bounded prefix before falling back to
                            // the established PCM path.
                            continue
                        }
                    }
                    if let resolved = profiles.first(where: \.prefersSystemMediaPlayback)
                        ?? profiles.first {
                        return resolved.prefersSystemMediaPlayback ? resolved : nil
                    }
                }
                profile = nil
            } catch {
                plog("System audio profile probe fell back to PCM: \(error.localizedDescription)")
                profile = nil
            }
        } else {
            profile = nil
        }
        return profile?.prefersSystemMediaPlayback == true ? profile : nil
    }

    private func fetchSystemAudioMetadataRange(
        for song: Song,
        url: URL,
        offset: Int64,
        length: Int64
    ) async throws -> Data {
        if isDLNACast(song),
           let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            return try await SourceManager.fetchRemoteMetadataRange(
                url: url,
                offset: offset,
                length: length,
                intent: .bulkBounded
            )
        }
        guard let sourceManager else {
            throw SourceError.connectionFailed("Audio metadata source unavailable")
        }
        return try await sourceManager.fetchMetadataRange(
            for: song,
            offset: offset,
            length: length,
            intent: .bulkBounded
        )
    }

    private nonisolated static func readPreferredSystemAudioProfile(
        from url: URL,
        fileSize declaredSize: Int64
    ) -> ISOBaseMediaAudioProfile? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let actualSize = (try? handle.seekToEnd()).map(Int64.init(clamping:)) ?? declaredSize
        guard actualSize > 0 else { return nil }
        let byteCount = min(
            Int64(RemoteMetadataReadPolicy.maximumHeadByteCount),
            actualSize
        )
        try? handle.seek(toOffset: 0)
        guard let head = try? handle.read(upToCount: Int(byteCount)) else { return nil }
        var profiles = ISOBaseMediaAudioProfileParser.parse(head: head)
        if profiles.isEmpty, byteCount < actualSize {
            try? handle.seek(toOffset: UInt64(actualSize - byteCount))
            if let tail = try? handle.read(upToCount: Int(byteCount)) {
                profiles = ISOBaseMediaAudioProfileParser.parse(head: head, tail: tail)
            }
        }
        return profiles.first(where: \.prefersSystemMediaPlayback) ?? profiles.first
    }

    private func startSystemAudioPlaybackIfPreferred(
        for song: Song,
        url: URL,
        playID id: UUID,
        sourceStreamEpoch: UInt64
    ) async -> Bool {
        let requestedPlaybackRate = playbackSettings.outputMode == .effects
            ? playbackSettings.playbackRate
            : 1
        // The established PCM graph owns variable-speed playback. Keep that
        // path whenever the user requests a non-default rate so the UI and
        // audible transport cannot disagree about elapsed time.
        guard abs(requestedPlaybackRate - 1) < 0.001 else { return false }
        guard let profile = await preferredSystemAudioProfile(for: song, url: url),
              playID == id,
              isLocalTransportStartAuthorized(
                playID: id,
                itemID: song.id,
                trigger: "system-multichannel-audio-start"
              ) else { return false }

        var loader: SystemAudioStreamingLoader?
        let asset: AVURLAsset
        if url.scheme == SourceManager.cloudStreamingScheme {
            guard let manager = sourceManager,
                  let inputSource = try? await manager.makeStreamingInputSource(
                    for: song,
                    cacheEnabled: playbackSettings.audioCacheEnabled,
                    expectedStreamEpoch: sourceStreamEpoch
                  ),
                  let cloudInput = inputSource as? CloudInputSourceObjC else {
                return false
            }
            let candidate = SystemAudioStreamingLoader(
                inputSource: cloudInput,
                fileExtension: "m4a"
            )
            guard let streamingAsset = candidate.makeAsset() else {
                candidate.invalidate()
                return false
            }
            loader = candidate
            asset = streamingAsset
        } else if url.scheme == "http" || url.scheme == "https" {
            guard let inputSource = await makeHTTPStreamingInputSource(
                for: song,
                url: url,
                sourceStreamEpoch: sourceStreamEpoch
            ), let cloudInput = inputSource as? CloudInputSourceObjC else {
                return false
            }
            let candidate = SystemAudioStreamingLoader(
                inputSource: cloudInput,
                fileExtension: "m4a"
            )
            guard let streamingAsset = candidate.makeAsset() else {
                candidate.invalidate()
                return false
            }
            loader = candidate
            asset = streamingAsset
        } else {
            asset = AVURLAsset(url: url)
        }

        guard playID == id else {
            loader?.invalidate()
            return false
        }
        _ = AudioSessionManager.shared.activatePlaybackSession()
        stopMusicVideoPlayback(clearPlayer: true)
        let item = AVPlayerItem(asset: asset)
        item.allowedAudioSpatializationFormats = .multichannel
        let player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = true
        player.volume = audioEngine.userVolume
        systemAudioPlayer = player
        systemAudioStreamingLoader = loader
        systemAudioFallbackContext = (song, url, sourceStreamEpoch)
        systemAudioPlaybackDidStart = false
        pendingSystemAudioSeek = nil
        isSystemAudioPlaybackActive = true
        isAtTrackEnd = false
        currentTime = 0
        duration = song.duration.sanitizedDuration
        isLoading = true
        isPlaying = false
        hasPreparedLocalPlayback = false
        activeDecoderKind = .native
        configureMusicVideoObservers(for: player, playID: id)
        plog("System multichannel audio: codec=\(profile.codecFourCC) channels=\(profile.channelCount) transport=AVPlayer")

        player.play()
        armSystemAudioStartupWatchdog(player: player, playID: id)
        updateNowPlayingInfo()
        updateNowPlayingArtworkIfNeeded()
        updatePlaybackState()
        return true
    }

    private func markSystemAudioPlaybackStarted(player: AVPlayer, playID id: UUID) {
        guard playID == id,
              isSystemAudioPlaybackActive,
              systemAudioPlayer === player,
              !systemAudioPlaybackDidStart,
              let song = currentSong,
              isLocalTransportStartAuthorized(
                playID: id,
                itemID: song.id,
                trigger: "system-multichannel-audio-playing"
              ) else { return }
        systemAudioPlaybackDidStart = true
        if pendingSystemAudioSeek?.playID == id {
            pendingSystemAudioSeek = nil
        }
        systemAudioStartupWatchdog?.cancel()
        systemAudioStartupWatchdog = nil
        isLoading = false
        isPlaying = true
        clearPendingPlaybackRecovery()
        library?.recordPlayback(of: song.id)
        ScrobbleService.shared.handlePlaybackStarted(song: song)
        PlayHistoryStore.shared.beginSession(song: song)
        updateNowPlayingInfo()
        updateNowPlayingArtworkIfNeeded()
        updatePlaybackState()
    }

    func armSystemAudioStartupWatchdog(player: AVPlayer, playID id: UUID) {
        systemAudioStartupWatchdog?.cancel()
        systemAudioStartupWatchdog = Task { @MainActor [weak self, weak player] in
            do {
                try await Task.sleep(for: .seconds(Self.firstBufferTimeoutSeconds))
            } catch {
                return
            }
            guard let self,
                  let player,
                  self.playID == id,
                  self.systemAudioPlayer === player,
                  self.isSystemAudioPlaybackActive,
                  !self.systemAudioPlaybackDidStart,
                  self.interruptionResumePolicy.playbackIsIntended else { return }
            await self.fallbackSystemAudioToPCM(
                playID: id,
                error: CocoaError(.fileReadUnknown)
            )
        }
    }

    private func fallbackSystemAudioToPCM(playID id: UUID, error: Error?) async {
        guard playID == id,
              isSystemAudioPlaybackActive,
              let fallback = systemAudioFallbackContext,
              currentSong?.id == fallback.song.id else { return }

        let pendingSeek = pendingSystemAudioSeek.flatMap { pending in
            pending.playID == id && pending.songID == fallback.song.id ? pending : nil
        }
        syncPlaybackProgressFromEngine()
        let resumeTime = max(0, pendingSeek?.time ?? currentTime)
        let alreadyRecordedPlaybackStart = systemAudioPlaybackDidStart
        let shouldResume = pendingSeek?.shouldStart
            ?? interruptionResumePolicy.playbackIsIntended
        plog(
            "System multichannel playback unavailable; using PCM fallback at "
                + "\(String(format: "%.2f", resumeTime))s: "
                + (error?.localizedDescription ?? "-")
        )
        stopMusicVideoPlayback(clearPlayer: true)
        guard playID == id, currentSong?.id == fallback.song.id else { return }

        guard shouldResume else {
            isLoading = false
            isPlaying = false
            pendingRecoveryTime = resumeTime
            needsPlaybackRecovery = resumeTime > 0
            updateNowPlayingInfo()
            updatePlaybackState()
            return
        }

        isLoading = true
        isPlaying = false
        await playFromURL(
            song: fallback.song,
            url: fallback.url,
            playID: id,
            sourceStreamEpoch: fallback.streamEpoch,
            bypassSystemMediaPlayback: true,
            shouldRecordPlaybackStart: !alreadyRecordedPlaybackStart
        )
        guard playID == id,
              currentSong?.id == fallback.song.id,
              interruptionResumePolicy.playbackIsIntended else { return }
        if resumeTime > 0, isPlaying, !isLoading {
            seek(to: resumeTime, startPlaying: true, isRecovery: true)
        }
    }

    private enum MusicVideoStartResult {
        case started
        case skipped
        case needsAudioFallback
        case cancelled
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

        pendingMusicVideoPlayID = id
        defer {
            if pendingMusicVideoPlayID == id {
                pendingMusicVideoPlayID = nil
            }
        }
        do {
            let resolved = try await sourceManager.resolveVideoAsset(for: song)
            guard pendingMusicVideoPlayID == id else { return .cancelled }
            guard let resolved else { return .needsAudioFallback }
            guard playID == id else { return .started }
            guard song.isStandaloneMusicVideo
                    || (isMusicVideoModeEnabled && !shouldForceAudioOnly) else {
                return .needsAudioFallback
            }
            guard isLocalTransportStartAuthorized(
                playID: id,
                itemID: song.id,
                trigger: "music-video-start"
            ) else {
                isLoading = false
                isPlaying = false
                needsPlaybackRecovery = true
                pendingRecoveryTime = currentTime
                updateNowPlayingInfo()
                updatePlaybackState()
                return .cancelled
            }

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
            player.volume = audioEngine.userVolume
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
            guard pendingMusicVideoPlayID == id else { return .cancelled }
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

    func configureMusicVideoObservers(for player: AVPlayer, playID id: UUID) {
        removeMusicVideoObservers()
        let observerGeneration = musicVideoObserverGeneration
        let advanceTicket = playbackAdvancePolicy.activeTicket
        let interval = CMTime(seconds: Self.timeUpdateInterval, preferredTimescale: 600)
        musicVideoTimeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self, weak player] time in
            Task { @MainActor [weak self, weak player] in
                guard let self,
                      let player,
                      self.musicVideoObserverGeneration == observerGeneration,
                      self.playID == id,
                      self.activeSystemMediaPlayer === player,
                      self.isSystemMediaPlaybackActive else { return }
                if self.isSystemAudioPlaybackActive,
                   player.timeControlStatus == .playing {
                    self.markSystemAudioPlaybackStarted(player: player, playID: id)
                }
                guard self.isPlaying else { return }
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

        musicVideoTimeControlObservation = player.observe(
            \.timeControlStatus,
            options: [.initial, .new]
        ) { [weak self, weak player] observed, _ in
            guard observed.timeControlStatus == .playing else { return }
            Task { @MainActor [weak self, weak player] in
                guard let self,
                      let player,
                      self.musicVideoObserverGeneration == observerGeneration,
                      self.playID == id,
                      self.systemAudioPlayer === player,
                      self.isSystemAudioPlaybackActive else { return }
                self.markSystemAudioPlaybackStarted(player: player, playID: id)
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
                    guard let self,
                          self.musicVideoObserverGeneration == observerGeneration,
                          self.playID == id else { return }
                    await self.handleMusicVideoPlaybackFailure(
                        playID: id,
                        advanceTicket: advanceTicket,
                        error: error,
                        item: box.item
                    )
                }
            }

            musicVideoFailedObserver = NotificationCenter.default.addObserver(
                forName: AVPlayerItem.failedToPlayToEndTimeNotification,
                object: item,
                queue: .main
            ) { [weak self] note in
                let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
                Task { @MainActor [weak self] in
                    guard let self,
                          self.musicVideoObserverGeneration == observerGeneration,
                          self.playID == id else { return }
                    await self.handleMusicVideoPlaybackFailure(
                        playID: id,
                        advanceTicket: advanceTicket,
                        error: error,
                        item: box.item
                    )
                }
            }
        }

        musicVideoEndObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: player.currentItem,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self,
                      self.musicVideoObserverGeneration == observerGeneration,
                      self.playID == id else { return }
                self.currentTime = self.duration
                guard let advanceTicket else { return }
                await self.handleTrackEnd(
                    advanceTicket: advanceTicket,
                    trigger: "music-video-end",
                    transportIsActive: self.isPlaying && self.isSystemMediaPlaybackActive
                )
            }
        }
    }

    private final class MusicVideoItemBox: @unchecked Sendable {
        let item: AVPlayerItem
        init(_ item: AVPlayerItem) { self.item = item }
    }

    private func handleMusicVideoPlaybackFailure(
        playID id: UUID,
        advanceTicket: PlaybackAdvanceTicket?,
        error: Error?,
        item: AVPlayerItem?
    ) async {
        guard playID == id, isSystemMediaPlaybackActive else { return }
        if isSystemAudioPlaybackActive {
            await fallbackSystemAudioToPCM(playID: id, error: error)
            return
        }
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
            guard let advanceTicket else { return }
            await autoAdvanceAfterFailure(
                advanceTicket: advanceTicket,
                trigger: "music-video-failure",
                transportIsActive: isPlaying && isSystemMediaPlaybackActive
            )
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
        musicVideoObserverGeneration &+= 1
        musicVideoSeekActivityEvidence = nil
        if let observer = musicVideoTimeObserver, let player = activeSystemMediaPlayer {
            player.removeTimeObserver(observer)
        }
        musicVideoTimeObserver = nil
        if let observer = musicVideoEndObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        musicVideoEndObserver = nil
        musicVideoStatusObservation?.invalidate()
        musicVideoStatusObservation = nil
        musicVideoTimeControlObservation?.invalidate()
        musicVideoTimeControlObservation = nil
        if let observer = musicVideoFailedObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        musicVideoFailedObserver = nil
    }

    func stopMusicVideoPlayback(clearPlayer: Bool) {
        guard musicVideoPlayer != nil
                || systemAudioPlayer != nil
                || isSystemMediaPlaybackActive
                || musicVideoStreamingLoader != nil
                || systemAudioStreamingLoader != nil else { return }
        activeSystemMediaPlayer?.pause()
        systemAudioStartupWatchdog?.cancel()
        systemAudioStartupWatchdog = nil
        removeMusicVideoObservers()
        if clearPlayer {
            musicVideoPlayer?.replaceCurrentItem(with: nil)
            musicVideoPlayer = nil
            musicVideoStreamingLoader?.invalidate()
            musicVideoStreamingLoader = nil
            systemAudioPlayer?.replaceCurrentItem(with: nil)
            systemAudioPlayer = nil
            systemAudioStreamingLoader?.invalidate()
            systemAudioStreamingLoader = nil
            systemAudioFallbackContext = nil
            pendingSystemAudioSeek = nil
        }
        isMusicVideoPlaybackActive = false
        isSystemAudioPlaybackActive = false
        systemAudioPlaybackDidStart = false
    }

    func showPlaybackError(_ message: String, automaticallyDismiss: Bool = true) {
        lastPlaybackError = message
        errorDismissTask?.cancel()
        errorDismissTask = nil
        guard automaticallyDismiss else { return }
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

    func beginPlaybackErrorScope() {
        errorDismissTask?.cancel()
        errorDismissTask = nil
        lastPlaybackError = nil
    }

    func dismissPlaybackError() {
        beginPlaybackErrorScope()
    }

    func suspendPlaybackAfterFailure(reason: String, message: String) {
        suspendPlaybackPreservingSelection(reason: reason)
        showPlaybackError(message, automaticallyDismiss: false)
    }

    func awaitFirstBuffer(
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

    func setPlaybackVolume(_ value: Float, persist: Bool = true) {
        guard value.isFinite else { return }
        let clamped = min(max(value, 0), 1)
        #if os(macOS)
        // 高保真直通的图里没有增益节点 —— 在那儿改应用音量是无声的操作，
        // 键盘快捷键和滑块都会看起来失灵。这种情况下音量由输出设备硬件承担。
        if PlaybackVolumeControlPolicy.target(
            isLiveRadio: isLiveRadio,
            isHighFidelityDirect: playbackSettings.outputMode == .highFidelity,
            outputDeviceVolumeIsControllable: OutputDeviceVolumeController.shared.isControllable
        ) == .outputDevice {
            OutputDeviceVolumeController.shared.setVolume(clamped)
            return
        }
        #endif
        audioEngine.setVolume(clamped, persist: persist)
        radioPlaybackController.setVolume(clamped)
        activeSystemMediaPlayer?.volume = clamped
    }

    func play(song: Song, caller: String = #fileID, callerLine: Int = #line) async {
        guard isSourceEnabledForPlayback(song.sourceID) else {
            plog("⛔ Playback ignored for disabled source id=\(song.sourceID.prefix(8))… song=\(song.id.prefix(8))…")
            showPlaybackError(String(localized: "playback_error_source_disabled"))
            return
        }
        preparePlaybackMetadataSelection(for: song)
        registerPlayIntent()
        if isLiveRadio {
            stopRadioTransport(clearSelection: true)
        }
        playbackKind = .track
        // Invalidate any pending operations immediately
        if pendingAppleMusicRestoredPosition?.songID != song.id {
            pendingAppleMusicRestoredPosition = nil
        }
        let id = UUID()
        playID = id
        // 拖动进度触发的整文件物化会一直下到底, 切歌 / 停止时必须一并取消,
        // 否则被放弃的传输继续占用带宽和缓存配额。Apple Music / 投屏分支在
        // 下面直接 return, 取消必须排在它们前面。
        // 重入说明: seek 任务自身会经「拖到曲尾自动续播」和「冷启动重播」
        // 回到这里, 那两个调用点都先把 seekTask 句柄摘成 nil, 所以这里永远
        // 不会取消正在执行本函数的那个任务。
        seekTask?.cancel()
        seekTask = nil
        let transportTicket = beginAutomaticAdvanceTransport(
            itemID: song.id,
            reason: "play-request"
        )
        // 退役是同步的 (只取消 control 并派生退役任务), 切到另一首时不必等上
        // 一首的整文件下载彻底收尾才发布 —— 那个等待留在唯一需要它的地方:
        // playWithStreamingDownload 安装新 session control 之前。
        // 唯一的例外是重新播放同一首: 退役任务的 finalizeStreamingSession 按
        // .partial 路径定位会话, 若不等它跑完, 它会把这一首刚建立的新流式
        // 会话当成自己的那个结束掉 (取消前台 Range 取数并释放缓存租约)。
        let deferredStreamingDownloadSongID = retireStreamingDownloadPreparation()
        if streamingDownloadRetirement?.songID == song.id {
            await awaitStreamingDownloadRetirement()
            guard playID == id else { return }
        }
        resetDecodedBufferHealth(resetRecoveryAttempts: true)
        beginPlaybackErrorScope()
        cancelCrossfadeAttempt()
        clearPendingPlaybackRecovery()
        prefetchTask?.cancel()
        prefetchTask = nil
        sourceManager?.cancelBackgroundAudioCaching(keeping: [song.id])
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
            guard await awaitCastingHandoffForLocalPlayback(ownerID: id),
                  isPendingTransportStartAuthorized(
                    playID: id,
                    itemID: song.id,
                    trigger: "play-after-casting-handoff",
                    expectedTicket: transportTicket
                  ) else {
                return
            }
        }

        // Apple Music 歌走系统侧 ApplicationMusicPlayer (DRM 流不能经
        // AVAudioEngine 解), 跨 player 切换 — 先停我们自己的播放器再让
        // AppleMusicService 接手, audio session 系统自动 hand-off。
        if song.sourceID == AppleMusicLibraryService.systemSourceID {
            guard isPendingTransportStartAuthorized(
                playID: id,
                itemID: song.id,
                trigger: "apple-music-handoff-start",
                expectedTicket: transportTicket
            ) else { return }
            stopMusicVideoPlayback(clearPlayer: true)
            await playAppleMusicSong(song, playID: id, transportTicket: transportTicket)
            return
        }

        // Cast 模式 ── 走 RemoteRendererController 推到远端 renderer, 不动
        // 本地 audioEngine。next/previous 走到这里时同样路由。
        if castingController != nil {
            stopMusicVideoPlayback(clearPlayer: true)
            await castSong(song, expectedTicket: transportTicket)
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
        // 把 .partial 转成 final (如果缺口在 50MB 自动补齐阈值内)。已被退役的
        // 那首由退役任务在下载与解码泵收尾后 finalize, 这里不能抢在前面。
        if StreamingDownloadRetirementPolicy.shouldFinalizePreviousSession(
            previousSongID: currentSong?.id,
            newSongID: song.id,
            retiredSongID: deferredStreamingDownloadSongID
        ), let prev = currentSong {
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
        // Loading can take up to the remote first-buffer timeout. Publish the
        // paused rate immediately so Lock Screen never keeps the previous
        // track's Pause icon while no audio is actually rendering.
        updateNowPlayingInfo()
        updateNowPlayingArtworkIfNeeded()
        updatePlaybackState()

        do {
            // Traversal excludes known outages; directly selecting one of
            // those entries retries its source without rebuilding the queue.
            if await sourceManager?.playbackSourceIsUnavailable(
                for: song, retryKnownUnavailable: true
            ) == true {
                throw SourceError.connectionFailed(String(localized: "status_network_unavailable"))
            }
            guard isLocalTransportStartAuthorized(
                playID: id,
                itemID: song.id,
                trigger: "play-after-source-probe",
                expectedTicket: transportTicket
            ) else { return }
            let musicVideoStartResult = await startMusicVideoPlaybackIfAvailable(for: song, playID: id)
            if case .started = musicVideoStartResult {
                sourceManager?.cancelBackgroundAudioCaching(keeping: [])
                return
            }
            if case .cancelled = musicVideoStartResult { return }

            let sourceStreamEpoch = CloudPlaybackSource.streamEpochTicket(
                sourceID: song.sourceID
            )
            await sourceManager?.waitForBackgroundAudioCache(for: song)
            guard isLocalTransportStartAuthorized(
                playID: id,
                itemID: song.id,
                trigger: "play-after-cache-wait",
                expectedTicket: transportTicket
            ) else { return }
            let url = try await resolvedURL(for: song)
            // Check if another play was initiated while downloading
            guard isLocalTransportStartAuthorized(
                playID: id,
                itemID: song.id,
                trigger: "play-after-url-resolution",
                expectedTicket: transportTicket
            ) else { return }
            await playFromURL(
                song: song,
                url: url,
                playID: id,
                sourceStreamEpoch: sourceStreamEpoch
            )
            if case .needsAudioFallback = musicVideoStartResult {
                markMusicVideoAudioFallbackIfNeeded(playID: id)
            }
        } catch {
            let action = PlaybackPipelineFailurePolicy.action(
                requestIsCurrent: playID == id,
                error: error
            )
            switch action {
            case .discardStaleResult:
                return
            case .preserveCurrentItem:
                if let assetError = error as? AppleMusicLocalAssetError {
                    plog("Apple Music local playback rejected reason=\(assetError.rawValue)")
                    suspendPlaybackAfterFailure(
                        reason: "apple-music-local-asset-unavailable",
                        message: assetError.localizedDescription
                    )
                    return
                }
                plog("🛡️ Playback URL resolution cancelled; preserving current item '\(song.title)'")
                invalidateAutomaticAdvance(reason: "playback-resolution-cancelled")
                isLoading = false
                isPlaying = false
                hasPreparedLocalPlayback = false
                pendingRecoveryTime = currentTime
                needsPlaybackRecovery = currentTime > 0
                updateNowPlayingInfo()
                updatePlaybackState()
                return
            case .advanceAfterFailure:
                break
            }
            plog("Playback URL resolution error: \(error)")
            if playbackMetadataSourceType?(song.sourceID) == .appleMusicLibrary {
                suspendPlaybackAfterFailure(
                    reason: "apple-music-local-resolution-failure",
                    message: error.localizedDescription
                )
                return
            }
            showPlaybackError(String(localized: "playback_error_connection"))
            isLoading = false
            let sourceUnavailable = await isSourceWideResolutionFailure(error, sourceID: song.sourceID)
            guard playID == id else { return }
            if sourceUnavailable {
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
    private func playAppleMusicSong(
        _ song: Song,
        playID id: UUID,
        transportTicket: PlaybackAdvanceTicket
    ) async {
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
              activeAppleMusicRequestID == id,
              isPendingTransportStartAuthorized(
                playID: id,
                itemID: song.id,
                trigger: "apple-music-after-renderer-handoff",
                expectedTicket: transportTicket
              ) else {
            appleMusic.cancelPlaybackRequest(id)
            activeAppleMusicRequestID = nil
            return
        }
        currentSong = song
        currentTime = 0
        duration = song.duration
        isLoading = true
        isPlaying = false
        isAtTrackEnd = false
        updateNowPlayingInfo()
        updateNowPlayingArtworkIfNeeded()
        updatePlaybackState()

        // Native CarPlay/lock-screen commands are handled by MusicKit itself.
        // It needs the actual compatible traversal, while Primuse keeps the
        // complete queue and maps native transitions back to its slot UUIDs.
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
        let managedQueue = isPrimuseManagingAppleMusicQueue ? appleMusicQueueProjection() : nil
        let queueContext = queue.filter { $0.sourceID == AppleMusicLibraryService.systemSourceID }
        startAppleMusicMirror(requestID: id)
        let appleMusicLibrary = AppServices.shared.appleMusicLibrary

        // 15s 兜底必须先注册。Apple Music user-library sync 在缺 entitlement
        // 或系统账户服务异常时可能卡住；如果把 timeout 放在 await 之后,
        // UI 会永远停在 isLoading=true。
        appleMusicTimeoutTask = Task { @MainActor [weak self, songID = song.id] in
            try? await Task.sleep(for: .seconds(15))
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
                plog("⚠️Apple Music playback request timed out before start")
                am.failPlaybackRequest(id, message: message)
                self.isLoading = false
                self.lastPlaybackError = message
            case nil:
                return
            }
            self.appleMusicTimeoutTask = nil
            self.updateNowPlayingInfo()
            self.updatePlaybackState()
        }

        // 不阻塞 play(song:) 调用方。成功后 AppleMusicService 的 mirror 会把
        // nowPlaying / progress 同步回来；失败或卡住由上面的 timeout 收口。
        let playbackTask = Task { @MainActor [weak self] in
            if let managedQueue {
                await appleMusicLibrary.playManagedQueue(managedQueue, requestID: id)
            } else {
                await appleMusicLibrary.play(primuseSong: song, queueContext: queueContext, requestID: id)
            }
            guard let self,
                  self.activeAppleMusicRequestID == id,
                  self.playID == id else { return }
            self.appleMusicPlaybackTask = nil
            self.synchronizeAppleMusicQueue()
        }
        appleMusicPlaybackTask = playbackTask
    }

    private func appleMusicQueueProjection() -> AppleMusicLibraryService.ManagedQueue? {
        guard queueEntries.indices.contains(currentIndex),
              queueEntries[currentIndex].song.id == currentSong?.id
                || queueEntries[currentIndex].song.filePath == currentSong?.filePath else { return nil }
        if sleepStopAfterSongID == currentSong?.id {
            return .init(entries: [queueEntries[currentIndex]], startIndex: 0, repeatMode: .off)
        }
        let traversal = (usesManagedShuffleOrder ? shuffledIndices : Array(queueEntries.indices))
            .filter { queueEntries.indices.contains($0) && isSongAvailableForNewPlayback(queueEntries[$0].song) }
        let indices = PlaybackQueueSegmentPolicy.indices(traversal: traversal, currentIndex: currentIndex) {
            queueEntries[$0].song.sourceID == AppleMusicLibraryService.systemSourceID
        }
        guard let startIndex = indices.firstIndex(of: currentIndex) else { return nil }
        let nativeRepeat = repeatMode == .all && indices.count != traversal.count ? .off : repeatMode
        return .init(entries: indices.map { queueEntries[$0] }, startIndex: startIndex, repeatMode: nativeRepeat)
    }

    func synchronizeAppleMusicQueue() {
        appleMusicQueueUpdateTask?.cancel()
        appleMusicQueueUpdateTask = nil
        if isPrimuseManagingAppleMusicQueue, queueEntries.isEmpty {
            AppServices.shared.appleMusic.retainCurrentManagedQueueEntry()
            return
        }
        guard isPrimuseManagingAppleMusicQueue,
              let requestID = activeAppleMusicRequestID,
              AppServices.shared.appleMusic.playbackPhase(for: requestID) == .started else { return }
        guard let projection = appleMusicQueueProjection() else {
            AppServices.shared.appleMusic.retainCurrentManagedQueueEntry()
            return
        }
        appleMusicQueueUpdateTask = Task { @MainActor in
            await AppServices.shared.appleMusicLibrary.updateManagedQueue(projection, requestID: requestID)
        }
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
                 _ = am.nowPlayingQueueEntryID
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

     func stopAppleMusicMirror() {
         // Bump before cancellation. `stopAppleMusic()` immediately changes
         // observed values and may wake the old checked continuation before
         // its cancelled task has otherwise had a chance to exit.
         appleMusicMirrorGeneration &+= 1
         appleMusicQueueUpdateTask?.cancel()
         appleMusicQueueUpdateTask = nil
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
         let previousPlayingState = isPlaying
         let previousLoadingState = isLoading
         switch phase {
         case .pending:
             return
         case .failed(let playbackError):
             lastPlaybackError = playbackError
             isLoading = false
             isPlaying = false
             pendingAppleMusicRestoredPosition = nil
             updateNowPlayingInfo()
             updatePlaybackState()
             return
         case .started:
             lastPlaybackError = nil
             isLoading = false
             isPlaying = am.isAppleMusicPlaying
         }
         if previousPlayingState != isPlaying || previousLoadingState != isLoading {
             updateNowPlayingInfo()
             updatePlaybackState()
         }
         guard let nps = am.nowPlayingSong else { return }
         isMirroringFromAppleMusic = true
         defer { isMirroringFromAppleMusic = false }

         // Adopt only a known occurrence in this queue. A native segment must
         // never replace the canonical mixed queue or collapse duplicate songs.
         if isPrimuseManagingAppleMusicQueue,
            let entryID = am.nowPlayingQueueEntryID,
            let index = queueEntries.firstIndex(where: { $0.id == entryID }),
            index != currentIndex || queueEntries[index].song.id != currentSong?.id {
             let song = queueEntries[index].song
             currentIndex = index
             if usesManagedShuffleOrder, let position = shuffledIndices.firstIndex(of: index) {
                 shufflePosition = position
             }
             currentSong = song
             currentTime = am.currentPlaybackTime
             duration = am.currentDuration > 0 ? am.currentDuration : song.duration
             isAtTrackEnd = false
             _ = beginAutomaticAdvanceTransport(itemID: song.id, reason: "apple-music-native-transition")
             library?.recordPlayback(of: song.id)
             ScrobbleService.shared.handlePlaybackStarted(song: song)
             PlayHistoryStore.shared.beginSession(song: song)
             persistPlaybackSession()
             updateNowPlayingInfo()
             updateNowPlayingArtworkIfNeeded()
             updatePlaybackState()
             synchronizeAppleMusicQueue()
             plog("Apple Music native transition adopted index=\(index) queueCount=\(queueEntries.count)")
         }
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
         if isPlaying, needsPlaybackRecovery {
             clearPendingPlaybackRecovery()
         }
         // 首次播 (isLoading=true) 收到 playing 状态才清 isLoading,
         // 避免 polling 命中前 UI 一直显示 spinner。
         currentTime = am.currentPlaybackTime
         if am.currentDuration > 0 { duration = am.currentDuration }
         if let restored = pendingAppleMusicRestoredPosition,
            restored.songID == pSong.id {
             am.seekAppleMusic(to: restored.time)
             currentTime = restored.time
             pendingAppleMusicRestoredPosition = nil
             clearPendingPlaybackRecovery()
         }
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

    /// At the end of a native segment, Primuse performs the next provider
    /// handoff or stops at the end of its canonical queue.
    func handleAppleMusicPlaybackEnded(requestID: UUID) {
        mirrorAppleMusicState(sessionGeneration: appleMusicMirrorGeneration, requestID: requestID)
        let appleMusic = AppServices.shared.appleMusic
        guard isPrimuseManagingAppleMusicQueue,
              isAppleMusicMode,
              activeAppleMusicRequestID == requestID,
              playID == requestID,
              interruptionResumePolicy.playbackIsIntended,
              appleMusic.isPlaybackRequestActive(requestID) else { return }
        Task { @MainActor [weak self] in
            guard let self,
                  self.activeAppleMusicRequestID == requestID,
                  self.playID == requestID,
                  self.interruptionResumePolicy.playbackIsIntended,
                  AppServices.shared.appleMusic.isPlaybackRequestActive(requestID) else { return }
            await self.handleAppleMusicTrackEnd(requestID: requestID)
        }
    }

    func play(
        song: Song,
        from url: URL,
        bypassSystemMediaPlayback: Bool = false,
        shouldRecordPlaybackStart: Bool = true
    ) async {
        registerPlayIntent()
        let sourceStreamEpoch = CloudPlaybackSource.streamEpochTicket(
            sourceID: song.sourceID
        )
        if isLiveRadio {
            stopRadioTransport(clearSelection: true)
        }
        playbackKind = .track
        // 与主 play(song:) 一致的路由: 投屏时推远端、Apple Music 镜像时先停镜像。
        // 否则本地 audioEngine 会与远端 renderer / 系统播放器同时出声, 且 mirror task
        // 仍会把 currentSong 改回 Apple Music 那首。
        let id = UUID()
        playID = id
        let transportTicket = beginAutomaticAdvanceTransport(
            itemID: song.id,
            reason: "direct-url-play-request"
        )
        resetDecodedBufferHealth(resetRecoveryAttempts: true)
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
            guard await awaitCastingHandoffForLocalPlayback(ownerID: id),
                  isPendingTransportStartAuthorized(
                    playID: id,
                    itemID: song.id,
                    trigger: "direct-url-after-casting-handoff",
                    expectedTicket: transportTicket
                  ) else {
                return
            }
        }

        if castingController != nil {
            await castSong(song, expectedTicket: transportTicket)
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
        await playFromURL(
            song: song,
            url: url,
            playID: id,
            sourceStreamEpoch: sourceStreamEpoch,
            bypassSystemMediaPlayback: bypassSystemMediaPlayback,
            shouldRecordPlaybackStart: shouldRecordPlaybackStart
        )
    }

    private func playFromURL(
        song: Song,
        url: URL,
        playID id: UUID,
        sourceStreamEpoch: UInt64,
        formatRecoveryAttempt: Int = 0,
        bypassSystemMediaPlayback: Bool = false,
        shouldRecordPlaybackStart: Bool = true
    ) async {
        plog("▶️ playFromURL(song: \(song.title)) playID=\(id.uuidString.prefix(8))")
        plog("▶️   URL: \(redactedURL(url))")
        plog("▶️   scheme=\(url.scheme ?? "nil") isFileURL=\(url.isFileURL) ext=\(url.pathExtension) format=\(song.fileFormat) duration=\(song.duration)")
        let isRemoteURL = url.scheme == "http" || url.scheme == "https"
        let isCloudStream = url.scheme == SourceManager.cloudStreamingScheme
        let requiresCurrentStreamEpoch = isRemoteURL || isCloudStream
        let streamEpochIsCurrent = !requiresCurrentStreamEpoch
            || CloudPlaybackSource.isStreamEpochTicketCurrent(
                sourceID: song.sourceID,
                ticket: sourceStreamEpoch
            )
        guard PlaybackURLRequestPolicy.canBegin(
            requestID: id,
            activeRequestID: playID,
            isCancelled: Task.isCancelled,
            requiresCurrentStreamEpoch: requiresCurrentStreamEpoch,
            streamEpochIsCurrent: streamEpochIsCurrent
        ) else {
            return
        }
        currentSong = song
        duration = song.duration.sanitizedDuration
        isLoading = true
        isPlaying = false
        hasPreparedLocalPlayback = false
        audioEngine.sampleTimeOffset = 0
        crossfadeTriggered = false; isCrossfading = false
        activeDecoderKind = .native
        var activeDSDMode: DSDPlaybackMode = .pcm

        if !bypassSystemMediaPlayback,
           await startSystemAudioPlaybackIfPreferred(
            for: song,
            url: url,
            playID: id,
            sourceStreamEpoch: sourceStreamEpoch
           ) {
            return
        }

        let remoteWAVProbeOutcome: RemoteWAVPlaybackPolicy.ProbeOutcome?
        if (isRemoteURL || isCloudStream), song.fileFormat == .wav {
            remoteWAVProbeOutcome = await probeRemoteWAVPayload(for: song)
        } else {
            remoteWAVProbeOutcome = nil
        }
        let remoteWAVRequiresCompleteFile = remoteWAVProbeOutcome.map {
            RemoteWAVPlaybackPolicy.requiresCompleteFile(
                persistedFormat: song.fileFormat,
                probeOutcome: $0
            )
        } ?? false

        let decoderAvailable: Bool
        if isRemoteURL || isCloudStream || nativeDecoder.canDecode(url: url) {
            decoderAvailable = true
        } else {
            decoderAvailable = await ffmpegCanDecodeOffMain(url)
        }
        guard playID == id else { return }
        guard decoderAvailable else {
            plog("Unsupported format: \(url.pathExtension)")
            isLoading = false
            await autoAdvanceAfterFailure()
            return
        }

        do {
            activeDSDMode = try await configureOutputPipeline(
                for: song,
                url: url,
                expectedPlayID: id
            )
            guard playID == id else { return }
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
            var completeRemoteWAVLocalURL: URL?
            if isCloudStream, remoteWAVRequiresCompleteFile,
               let manager = sourceManager {
                let completeURL = try await manager.resolveFullDownloadSourceURL(for: song)
                guard playID == id else { return }
                if completeURL.scheme == "http" || completeURL.scheme == "https" {
                    let probeDescription = remoteWAVProbeOutcome.map(String.init(describing:))
                        ?? "unavailable"
                    plog("▶️ Decoder: full-download WAV safety path (remote DTS probe: \(probeDescription))")
                    let cacheURL = playbackSettings.audioCacheEnabled ? manager.cacheURL(for: song) : nil
                    await playWithStreamingDownload(
                        song: song,
                        url: completeURL,
                        outputFormat: outputFormat,
                        playID: id,
                        cacheURL: cacheURL,
                        sourceStreamEpoch: sourceStreamEpoch,
                        shouldRecordPlaybackStart: shouldRecordPlaybackStart
                    )
                    return
                }
                completeRemoteWAVLocalURL = completeURL
            }

            let stream: AudioBufferStream
            if isRemoteURL {
                if FileFormatRouter.requiresCompleteLocalFile(song.fileFormat)
                    || remoteWAVRequiresCompleteFile {
                    let reason = remoteWAVRequiresCompleteFile
                        ? "remote WAV content probe requires safe local routing"
                        : "custom formats require a local seekable stream"
                    plog("▶️ Decoder: full-download (\(reason))")
                    let cacheURL = playbackSettings.audioCacheEnabled ? sourceManager?.cacheURL(for: song) : nil
                    await playWithStreamingDownload(
                        song: song,
                        url: url,
                        outputFormat: outputFormat,
                        playID: id,
                        cacheURL: cacheURL,
                        sourceStreamEpoch: sourceStreamEpoch,
                        shouldRecordPlaybackStart: shouldRecordPlaybackStart
                    )
                    return
                }
                if SourceManager.isTranscodedStreamURL(url), assetReaderDecoder.canDecode(url: url) {
                    // 服务端转码流(Subsonic WMA→mp3, 大小未知): 走 AVAssetReader 渐进
                    // 解码。不按 song.fileSize 做 HTTP Range(会读越界), 也不写按
                    // 大小校验的持久缓存。
                    plog("▶️ Decoder: AVAssetReader (reason: server transcoded stream, progressive, unknown length) outputFormat: sr=\(outputFormat.sampleRate) ch=\(outputFormat.channelCount)")
                    await playWithFallbackDecoder(
                        song: song,
                        url: url,
                        outputFormat: outputFormat,
                        playID: id,
                        shouldRecordPlaybackStart: shouldRecordPlaybackStart
                    )
                    return
                }
                if let inputSource = await makeHTTPStreamingInputSource(
                    for: song,
                    url: url,
                    sourceStreamEpoch: sourceStreamEpoch
                ) {
                    plog("▶️ Decoder: HTTPRangePlaybackSource (reason: scheme=\(url.scheme ?? "?"), range-based HTTP streaming) cache=\(playbackSettings.audioCacheEnabled) outputFormat: sr=\(outputFormat.sampleRate) ch=\(outputFormat.channelCount)")
                    activeDecoderKind = .httpStream
                    stream = nativeDecoder.decode(from: inputSource, outputFormat: outputFormat, onResolveSourceLength: makeResolveLengthCallback(for: song))
                } else if song.fileSize > 0 {
                    guard playID == id else { return }
                    plog("⚠️ HTTP range cache admission denied for known-size media; refusing unreserved full download")
                    showPlaybackError(String(localized: "offline_download_failed"))
                    isLoading = false
                    republishNowPlayingSurfaces()
                    return
                } else if isDLNACast(song), assetReaderDecoder.canDecode(url: url) {
                    // DLNA control points often push CGI/progressive URLs
                    // with no Content-Length. Full-download fallback waits
                    // for EOF before decoding, which leaves the sender stuck
                    // on loading. Let AVFoundation open the remote asset
                    // progressively before trying the legacy full download.
                    plog("▶️ Decoder: AVAssetReader (reason: DLNA URL has no range/fileSize, progressive remote fallback) outputFormat: sr=\(outputFormat.sampleRate) ch=\(outputFormat.channelCount)")
                    await playWithFallbackDecoder(
                        song: song,
                        url: url,
                        outputFormat: outputFormat,
                        playID: id,
                        shouldRecordPlaybackStart: shouldRecordPlaybackStart
                    )
                    return
                } else {
                    // Fallback for legacy rows / arbitrary URLs where fileSize is
                    // unknown. This preserves compatibility but still logs clearly
                    // that startup waits for a full download.
                    plog("▶️ Decoder: StreamingDownloadDecoder (reason: HTTP range unavailable or fileSize unknown, full-download fallback) outputFormat: sr=\(outputFormat.sampleRate) ch=\(outputFormat.channelCount)")
                    let cacheURL = playbackSettings.audioCacheEnabled ? sourceManager?.cacheURL(for: song) : nil
                    await playWithStreamingDownload(
                        song: song,
                        url: url,
                        outputFormat: outputFormat,
                        playID: id,
                        cacheURL: cacheURL,
                        sourceStreamEpoch: sourceStreamEpoch,
                        shouldRecordPlaybackStart: shouldRecordPlaybackStart
                    )
                    return
                }
            } else if let completeRemoteWAVLocalURL {
                let shouldUseFFmpeg: Bool
                if remoteWAVProbeOutcome == .dts {
                    shouldUseFFmpeg = true
                } else {
                    shouldUseFFmpeg = await usesFFmpegDecoder(
                        for: song,
                        url: completeRemoteWAVLocalURL
                    )
                }
                if shouldUseFFmpeg {
                    activeDecoderKind = .ffmpeg
                    plog("▶️ Decoder: FFmpeg (reason: complete remote WAV safety path)")
                    stream = ffmpegDecoder.decode(
                        from: completeRemoteWAVLocalURL,
                        outputFormat: outputFormat,
                        onResolveSourceLength: makeResolveLengthCallback(for: song)
                    )
                } else {
                    plog("▶️ Decoder: NativeDecoder (reason: complete remote PCM WAV after unavailable prefix probe)")
                    stream = nativeDecoder.decode(
                        from: completeRemoteWAVLocalURL,
                        outputFormat: outputFormat,
                        onResolveSourceLength: makeResolveLengthCallback(for: song)
                    )
                }
            } else if isCloudStream, let manager = sourceManager {
                let inputSource: InputSource?
                do {
                    inputSource = try await manager.makeStreamingInputSource(
                        for: song,
                        cacheEnabled: playbackSettings.audioCacheEnabled,
                        expectedStreamEpoch: sourceStreamEpoch
                    )
                } catch is CancellationError {
                    guard playID == id else { return }
                    isLoading = false
                    return
                } catch let error as OfflineTransferValidationError {
                    guard playID == id else { return }
                    plog("⚠️ Cloud range cache admission failed: \(error.localizedDescription)")
                    showPlaybackError(String(localized: "offline_download_failed"))
                    isLoading = false
                    await autoAdvanceAfterFailure()
                    return
                } catch {
                    guard !Task.isCancelled, playID == id else { return }
                    if OperationCancellationPolicy.isCancellation(error) {
                        isLoading = false
                        return
                    }
                    plog("⚠️ Cloud range setup failed: \(error.localizedDescription)")
                    showPlaybackError(String(localized: "playback_error_connection"))
                    isLoading = false
                    let sourceUnavailable = await isSourceWideResolutionFailure(error, sourceID: song.sourceID)
                    guard playID == id else { return }
                    await autoAdvanceAfterFailure(skippingSourceID: sourceUnavailable ? song.sourceID : nil)
                    return
                }
                guard let inputSource else {
                    guard !Task.isCancelled, playID == id else { return }
                    isLoading = false
                    if CloudPlaybackSource.isStreamEpochTicketCurrent(
                        sourceID: song.sourceID, ticket: sourceStreamEpoch
                    ) {
                        await autoAdvanceAfterFailure()
                    }
                    return
                }
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
                let reason = "local file path (file:// scheme)"
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
                    republishNowPlayingSurfaces()
                    await autoAdvanceAfterFailure()
                    return
                }
                guard playID == id else { return }
                firstBuffer = buffer
            } catch is CancellationError {
                guard !Task.isCancelled, playID == id else { return }
                // 云盘大文件逐 chunk 流式卡死(连接饥饿 / 冷文件 hydration)时,
                // 退回整文件渐进下载再试一次, 而不是直接报错跳过。
                if isCloudStream, await cloudFullDownloadFallback(
                    song: song,
                    outputFormat: outputFormat,
                    playID: id,
                    sourceStreamEpoch: sourceStreamEpoch,
                    shouldRecordPlaybackStart: shouldRecordPlaybackStart
                ) {
                    return
                }
                plog("⚠️ '\(song.title)' first-buffer timeout (35s) — likely cloud fetch stalled")
                showPlaybackError(String(localized: "playback_error_connection"))
                isLoading = false
                republishNowPlayingSurfaces()
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
                        await playWithFallbackDecoder(
                            song: song,
                            url: url,
                            outputFormat: outputFormat,
                            playID: id,
                            shouldRecordPlaybackStart: shouldRecordPlaybackStart
                        )
                    } else {
                        plog("↳ HTTP range decode failed before first buffer; falling back to full download")
                        guard await sourceManager?.cancelStreamingSessionForMaterialization(
                            for: song,
                            expectedStreamEpoch: sourceStreamEpoch
                        ) != false else { return }
                        let cacheURL = playbackSettings.audioCacheEnabled ? sourceManager?.cacheURL(for: song) : nil
                        await playWithStreamingDownload(
                            song: song,
                            url: url,
                            outputFormat: outputFormat,
                            playID: id,
                            cacheURL: cacheURL,
                            sourceStreamEpoch: sourceStreamEpoch,
                            shouldRecordPlaybackStart: shouldRecordPlaybackStart
                        )
                    }
                } else if !isCloudStream {
                    let safeOutputFormat = await preparePCMOutputAfterDoPFailure(
                        song: song,
                        url: url,
                        wasUsingDoP: activeDSDMode == .dop,
                        expectedPlayID: id
                    ) ?? outputFormat
                    guard playID == id else { return }
                    activeDSDPlaybackMode = .pcm
                    await playWithFallbackDecoder(
                        song: song,
                        url: url,
                        outputFormat: safeOutputFormat,
                        playID: id,
                        shouldRecordPlaybackStart: shouldRecordPlaybackStart
                    )
                } else if await cloudFullDownloadFallback(
                    song: song,
                    outputFormat: outputFormat,
                    playID: id,
                    sourceStreamEpoch: sourceStreamEpoch,
                    shouldRecordPlaybackStart: shouldRecordPlaybackStart
                ) {
                    return
                } else {
                    isLoading = false
                    republishNowPlayingSurfaces()
                }
                return
            }
            guard !isRemoteURL && !isCloudStream
                    || CloudPlaybackSource.isStreamEpochTicketCurrent(
                        sourceID: song.sourceID,
                        ticket: sourceStreamEpoch
                    ) else {
                isLoading = false
                return
            }

            let bufferMatchesGraph = DirectPCMOutputSampleRatePolicy.bufferMatchesGraph(
                bufferSampleRate: firstBuffer.format.sampleRate,
                bufferChannelCount: firstBuffer.format.channelCount,
                graphSampleRate: outputFormat.sampleRate,
                graphChannelCount: outputFormat.channelCount
            )
            let actualHardwareRate = audioEngine.currentHardwareSampleRate
            let hardwareRateIsKnown = DirectPCMOutputSampleRatePolicy.resolvedSampleRate(
                requestedSourceSampleRate: nil,
                actualHardwareSampleRate: actualHardwareRate
            ) != nil
            let graphMatchesHardware = audioEngine.outputMode != .highFidelity
                || !hardwareRateIsKnown
                || DirectPCMOutputSampleRatePolicy.hardwareMatches(
                    requestedSampleRate: outputFormat.sampleRate,
                    actualHardwareSampleRate: actualHardwareRate
                )
            if !bufferMatchesGraph || !graphMatchesHardware {
                plog(
                    "⚠️ PCM format changed before first schedule "
                        + "buffer=sr\(firstBuffer.format.sampleRate)/ch\(firstBuffer.format.channelCount) "
                        + "graph=sr\(outputFormat.sampleRate)/ch\(outputFormat.channelCount) "
                        + "hardware=sr\(actualHardwareRate); rebuilding once"
                )
                audioEngine.stopPlayback()
                guard formatRecoveryAttempt == 0 else {
                    throw AudioDecoderError.decodingFailed("PCM output format remained inconsistent after rebuild")
                }
                // Return first so the current AsyncStream iterator is released
                // and its decoder task is cancelled before the replacement
                // pipeline begins on the next MainActor turn.
                Task { @MainActor [weak self] in
                    guard let self,
                          PlaybackURLRequestPolicy.canBegin(
                            requestID: id,
                            activeRequestID: self.playID,
                            isCancelled: Task.isCancelled,
                            requiresCurrentStreamEpoch: requiresCurrentStreamEpoch,
                            streamEpochIsCurrent: !requiresCurrentStreamEpoch
                                || CloudPlaybackSource.isStreamEpochTicketCurrent(
                                    sourceID: song.sourceID,
                                    ticket: sourceStreamEpoch
                                )
                          ) else {
                        return
                    }
                    await self.playFromURL(
                        song: song,
                        url: url,
                        playID: id,
                        sourceStreamEpoch: sourceStreamEpoch,
                        formatRecoveryAttempt: formatRecoveryAttempt + 1,
                        bypassSystemMediaPlayback: bypassSystemMediaPlayback,
                        shouldRecordPlaybackStart: shouldRecordPlaybackStart
                    )
                }
                return
            }

            // Schedule first buffer BEFORE play — playerNode has data ready
            plog("▶️ Decoder firstBuffer: kind=\(activeDecoderKind) frames=\(firstBuffer.frameLength) format=sr\(firstBuffer.format.sampleRate)/ch\(firstBuffer.format.channelCount)")
            plog("▶️ Engine state: outputFormat=sr\(outputFormat.sampleRate)/ch\(outputFormat.channelCount) mainVol=\(audioEngine.volume)")
            plog("▶️ Engine diagnostics: \(audioEngine.diagnosticInfo())")
            let gate = DecodedBufferGate(
                maxBufferedDuration: Self.decodedAudioLookahead,
                maxBufferedBytes: Self.maxInFlightDecodedBytes,
                maxBufferCount: Self.maxInFlightDecodedBufferCount
            )
            await scheduleTrackedDecodedBuffer(firstBuffer, gate: gate)
            guard !Task.isCancelled, playID == id else {
                await gate.drain()
                return
            }
            installDecodedBufferGate(gate, playID: id)
            hasPreparedLocalPlayback = true
            guard isLocalTransportStartAuthorized(
                playID: id,
                itemID: song.id,
                trigger: "decoded-first-buffer"
            ) else {
                audioEngine.stopPlayback()
                hasPreparedLocalPlayback = false
                isLoading = false
                isPlaying = false
                needsPlaybackRecovery = currentSong?.id == song.id && !isAtTrackEnd
                pendingRecoveryTime = currentTime
                await gate.drain()
                republishNowPlayingSurfaces()
                return
            }
            let didStartPlayback = audioEngine.play()
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

            // Publish playing only after the underlying engine and player node
            // both confirm startup. A swallowed engine.start() error otherwise
            // leaves Control Center showing Pause while no audio exists.
            isPlaying = didStartPlayback
            isLoading = false
            if didStartPlayback {
                clearPendingPlaybackRecovery()
                if shouldRecordPlaybackStart {
                    library?.recordPlayback(of: song.id)
                    ScrobbleService.shared.handlePlaybackStarted(song: song)
                    PlayHistoryStore.shared.beginSession(song: song)
                }
                startTimeUpdater()
            } else {
                showPlaybackError(String(localized: "playback_error_decode"))
                stopTimeUpdater()
            }
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
            decodingTask = Task { [id, iteratorBox, gate] in
                var lastBuffer: AVAudioPCMBuffer?
                var midStreamError = false
                defer { Task { await gate.drain() } }

                // 稳态解码泵整体移出 MainActor: 循环本身不再读主 actor 状态, 归属改由
                // pumpLease 逐块回答; 收尾逻辑仍留在外层这个主 actor Task 里。
                let loop = DecodedBufferSchedulingLoop<AVAudioPCMBuffer, UUID>(
                    playID: id,
                    lease: self.pumpLease,
                    gate: gate,
                    measure: { buffer in
                        DecodedBufferMeasurement(
                            duration: Self.decodedBufferDuration(buffer),
                            byteCount: Self.decodedBufferByteCount(buffer)
                        )
                    },
                    schedule: { [audioEngine = self.audioEngine] buffer, release in
                        audioEngine.scheduleDecodedBuffer(
                            buffer, on: .primary, completionCallbackType: .dataPlayedBack
                        ) { _ in release() }
                    }
                )
                let loopTask = Task.detached(priority: .userInitiated) {
                    await loop.run(next: { try await iteratorBox.next() })
                }
                let outcome = await withTaskCancellationHandler {
                    await loopTask.value
                } onCancel: {
                    loopTask.cancel()
                }

                switch outcome {
                case .cancelled, .lostOwnership:
                    return
                case .completed(let buffer, _):
                    lastBuffer = buffer
                case .failed(let error, let buffer, let scheduledCount):
                    lastBuffer = buffer
                    guard !Task.isCancelled, self.playID == id else { return }
                    midStreamError = true
                    plog("⚠️ Decode error mid-stream for '\(song.title)' (scheduled \(scheduledCount) buffers): \(error.localizedDescription)")
                    if self.playbackSettings.audioCacheEnabled,
                       self.activeDecoderKind == .cloudStream || self.activeDecoderKind == .httpStream {
                        self.beginRemoteMidStreamRecovery(song: song, playID: id)
                        return
                    }
                    self.showPlaybackError(String(localized: "playback_error_decode"))
                    if scheduledCount < 3 {
                        // Too little decoded to be worth playing — bail now.
                        // Helper handles repeat-one (stop, don't loop broken
                        // file), shuffle correctness, and stop-when-no-next.
                        await self.autoAdvanceAfterFailure()
                        return
                    }
                }

                if !midStreamError, let finalBuffer = lastBuffer, !Task.isCancelled {
                    if self.scheduleOutgoingCrossfadeTailBuffer(finalBuffer, playID: id) { return }
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
                    guard let failureTicket = self.playbackAdvancePolicy.activeTicket else { return }
                    Task { @MainActor [id, failureTicket] in
                        try? await Task.sleep(for: .seconds(Self.midStreamErrorGrace))
                        guard self.playID == id else { return }
                        let wasActive = self.isPlaying && self.audioEngine.isActuallyPlaying
                        guard self.automaticAdvanceDecision(
                            for: failureTicket,
                            trigger: "mid-stream-grace",
                            consume: false,
                            transportIsActive: wasActive
                        ) == .accepted else { return }
                        plog("🛑 mid-stream grace elapsed; stopping engine and advancing")
                        self.audioEngine.stopPlayback()
                        await self.autoAdvanceAfterFailure(
                            advanceTicket: failureTicket,
                            trigger: "mid-stream-grace",
                            transportIsActive: wasActive
                        )
                    }
                } else if let finalBuffer = lastBuffer {
                    // Natural EOF — schedule with track-end completion.
                    await self.scheduleDecodedFinalBuffer(finalBuffer, playID: id)
                }
            }
        } catch {
            guard !Task.isCancelled, playID == id else { return }
            if PlaybackPipelineFailurePolicy.action(
                requestIsCurrent: true,
                error: error
            ) == .preserveCurrentItem {
                plog("⏸️ Playback preparation unavailable; keeping '\(song.title)': \(error)")
                suspendPlaybackPreservingSelection(
                    reason: "playback-preparation-unavailable",
                    resumeTime: currentTime
                )
                return
            }
            plog("⚠️ Playback error for '\(song.title)': \(error.localizedDescription)")
            showPlaybackError(String(localized: "playback_error_decode"))
            isLoading = false
            // Auto-skip on decode failure (or stop under repeat-one
            // instead of looping a broken file).
            await autoAdvanceAfterFailure()
        }
    }

    /// 云盘逐 chunk 流式失败(首缓冲超时 / serve 报错)时的兜底: 优先使用
    /// OneDrive 预授权直链渐进下载；WebDAV / NAS 等 connector 则通过统一的
    /// 完整文件缓存下载后重新打开，避免继续重复失败的 Range 请求。
    /// 返回 true 表示已接管(发起了下载或已切歌), 调用方不应再走默认错误分支。
    private func cloudFullDownloadFallback(
        song: Song,
        outputFormat: AVAudioFormat,
        playID id: UUID,
        sourceStreamEpoch: UInt64,
        shouldRecordPlaybackStart: Bool
    ) async -> Bool {
        guard let manager = sourceManager,
              let fallbackTicket = localPipelineAdvanceTicket else { return false }
        if let directURL = await manager.resolveDirectDownloadURL(for: song) {
            guard isLocalTransportStartAuthorized(
                playID: id,
                itemID: song.id,
                trigger: "cloud-direct-download-fallback",
                expectedTicket: fallbackTicket
            ) else { return true }
            plog("↳ cloud chunked-stream failed; falling back to full progressive download (\(song.fileSize / 1_048_576)MB) via \(directURL.host ?? "?")")
            guard await manager.cancelStreamingSessionForMaterialization(
                for: song,
                expectedStreamEpoch: sourceStreamEpoch
            ) else { return true }
            let cacheURL = playbackSettings.audioCacheEnabled ? manager.cacheURL(for: song) : nil
            await playWithStreamingDownload(
                song: song,
                url: directURL,
                outputFormat: outputFormat,
                playID: id,
                cacheURL: cacheURL,
                sourceStreamEpoch: sourceStreamEpoch,
                shouldRecordPlaybackStart: shouldRecordPlaybackStart
            )
            return true
        }

        guard isLocalTransportStartAuthorized(
            playID: id,
            itemID: song.id,
            trigger: "cloud-materialization-fallback",
            expectedTicket: fallbackTicket
        ) else { return true }

        guard playbackSettings.audioCacheEnabled else { return false }
        plog("↳ cloud chunked-stream failed; materializing a complete connector file")
        guard let cached = await manager.materializeCachedURLForSeeking(for: song) else {
            return false
        }
        guard isLocalTransportStartAuthorized(
            playID: id,
            itemID: song.id,
            trigger: "cloud-materialized-fallback",
            expectedTicket: fallbackTicket
        ) else { return true }
        audioEngine.stopPlayback()
        hasPreparedLocalPlayback = false
        stopTimeUpdater()
        cancelGaplessTasks()
        await playFromURL(
            song: song,
            url: cached,
            playID: id,
            sourceStreamEpoch: sourceStreamEpoch,
            bypassSystemMediaPlayback: true,
            shouldRecordPlaybackStart: shouldRecordPlaybackStart
        )
        return true
    }

    /// A connector-backed Range stream may fail after playback has already
    /// started. Materialize the same song once and resume from the audible
    /// position instead of converting a transient network timeout into a skip.
    /// This path is limited to enabled audio caching so it never persists a
    /// complete file behind the user's back when caching is disabled.
    func beginRemoteMidStreamRecovery(
        song: Song,
        playID id: UUID,
        frozenResumeTime: TimeInterval? = nil
    ) {
        guard let manager = sourceManager, playID == id else { return }
        stopTimeUpdater()
        let resumeTime: TimeInterval
        if let frozenResumeTime {
            resumeTime = max(0, frozenResumeTime)
        } else {
            syncPlaybackProgressFromEngine()
            resumeTime = max(0, currentTime)
        }
        plog(String(
            format: "↳ remote Range stream failed at %.2fs; materializing complete file for one-shot recovery",
            resumeTime
        ))

        decodingTask?.cancel()
        decodingTask = nil
        resetDecodedBufferHealth(resetRecoveryAttempts: false)
        invalidateAutomaticAdvance(reason: "remote-mid-stream-recovery")
        let recoveryTicket = beginAutomaticAdvanceTransport(
            itemID: song.id,
            reason: "remote-recovery-pending"
        )
        audioEngine.stopPlayback()
        isPlaying = false
        isLoading = true
        updateNowPlayingInfo()
        updatePlaybackState()

        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let cached = await manager.materializeCachedURLForSeeking(for: song) else {
                guard self.playID == id, self.currentSong?.id == song.id else { return }
                self.isLoading = false
                self.showPlaybackError(String(localized: "playback_error_connection"))
                await self.autoAdvanceAfterFailure(
                    advanceTicket: recoveryTicket,
                    trigger: "remote-recovery-failed",
                    transportIsActive: true
                )
                return
            }
            guard self.isLocalTransportStartAuthorized(
                playID: id,
                itemID: song.id,
                trigger: "remote-mid-stream-recovery-materialized",
                expectedTicket: recoveryTicket
            ) else {
                self.isLoading = false
                self.pendingRecoveryTime = resumeTime
                self.needsPlaybackRecovery = self.currentSong?.id == song.id
                self.republishNowPlayingSurfaces()
                return
            }

            self.activeDecoderKind = await self.usesFFmpegDecoder(for: song, url: cached)
                ? .ffmpeg
                : .native
            guard self.isLocalTransportStartAuthorized(
                playID: id,
                itemID: song.id,
                trigger: "remote-mid-stream-recovery-decoder",
                expectedTicket: recoveryTicket
            ) else {
                self.isLoading = false
                self.pendingRecoveryTime = resumeTime
                self.needsPlaybackRecovery = self.currentSong?.id == song.id
                self.republishNowPlayingSurfaces()
                return
            }
            plog("↳ remote playback recovered from complete local cache; resuming at \(String(format: "%.2f", resumeTime))s")
            self.seek(to: resumeTime, startPlaying: true, isRecovery: true)
        }
    }

    @discardableResult
    func retireStreamingDownloadPreparation(
        matchingID: UUID? = nil
    ) -> String? {
        guard let active = activeStreamingDownloadPreparation,
              matchingID == nil || active.id == matchingID else { return nil }
        activeStreamingDownloadPreparation = nil
        active.control.cancel()

        let retirementID = UUID()
        let preceding = streamingDownloadRetirement?.task
        let manager = sourceManager
        let task = Task { @MainActor [weak self] in
            if let preceding {
                await preceding.value
            }
            await active.control.waitForTermination()
            manager?.finalizeStreamingSession(for: active.song)
            guard let self,
                  self.streamingDownloadRetirement?.id == retirementID else { return }
            self.streamingDownloadRetirement = nil
        }
        streamingDownloadRetirement = StreamingDownloadRetirement(
            id: retirementID,
            songID: active.song.id,
            task: task
        )
        return active.song.id
    }

    private func awaitStreamingDownloadRetirement() async {
        while let retirement = streamingDownloadRetirement {
            await retirement.task.value
            if streamingDownloadRetirement?.id == retirement.id {
                streamingDownloadRetirement = nil
            }
        }
    }

    private func cancelAndAwaitStreamingDownloadPreparation(id: UUID) async {
        guard retireStreamingDownloadPreparation(matchingID: id) != nil else { return }
        await awaitStreamingDownloadRetirement()
    }

    private func completeStreamingDownloadPreparation(id: UUID) {
        guard activeStreamingDownloadPreparation?.id == id else { return }
        activeStreamingDownloadPreparation = nil
    }

    /// Full-download fallback for remote URLs whose length is unknown or
    /// whose server rejects Range reads. Handles self-signed HTTPS
    /// certificates that AVAssetReader cannot.
    private func playWithStreamingDownload(
        song: Song, url: URL, outputFormat: AVAudioFormat,
        playID id: UUID, cacheURL: URL?, sourceStreamEpoch: UInt64,
        shouldRecordPlaybackStart: Bool = true
    ) async {
        _ = retireStreamingDownloadPreparation()
        await awaitStreamingDownloadRetirement()
        guard CloudPlaybackSource.isStreamEpochTicketCurrent(
            sourceID: song.sourceID,
            ticket: sourceStreamEpoch
        ), playID == id else { return }

        guard let prepared = await sourceManager?.prepareHTTPStreamingCache(
            for: song,
            prefersPersistentCache: cacheURL != nil
        ) else {
            guard playID == id else { return }
            showPlaybackError(String(localized: "offline_download_failed"))
            isLoading = false
            return
        }
        guard CloudPlaybackSource.isStreamEpochTicketCurrent(
            sourceID: song.sourceID,
            ticket: sourceStreamEpoch
        ) else {
            sourceManager?.finalizeStreamingSession(for: song)
            return
        }
        guard await sourceManager?.cancelStreamingSessionForMaterialization(
            for: song,
            expectedStreamEpoch: sourceStreamEpoch
        ) != false,
              self.playID == id,
              CloudPlaybackSource.isStreamEpochTicketCurrent(
                  sourceID: song.sourceID,
                  ticket: sourceStreamEpoch
              ) else {
            sourceManager?.finalizeStreamingSession(for: song)
            return
        }
        let admittedCacheURL = prepared.persistOnComplete ? prepared.url : nil
        let admittedMaximumBytes = Int(clamping: prepared.maximumTransferBytes)
        let preparationID = UUID()
        let sessionControl = StreamingDownloadSessionControl()
        activeStreamingDownloadPreparation = ActiveStreamingDownloadPreparation(
            id: preparationID,
            song: song,
            control: sessionControl
        )
        let rawStream = streamingDecoder.decode(
            from: url,
            outputFormat: outputFormat,
            cacheFileURL: admittedCacheURL,
            fileExtension: song.fileFormat.rawValue,
            maximumDownloadBytes: admittedMaximumBytes,
            sourceID: song.sourceID,
            streamEpoch: sourceStreamEpoch,
            sessionControl: sessionControl,
            onResolveSourceLength: makeResolveLengthCallback(for: song)
        )
        let stream = segmented(rawStream, for: song)
        let iteratorBox = BufferIteratorBox(stream.makeAsyncIterator())

        do {
            guard let firstBuffer = try await awaitFirstBuffer(
                from: iteratorBox,
                timeoutSeconds: Self.remoteFallbackFirstBufferTimeoutSeconds
            ) else {
                await cancelAndAwaitStreamingDownloadPreparation(id: preparationID)
                guard playID == id else { return }
                plog("⚠️ StreamingDownload: empty stream for '\(song.title)'")
                isLoading = false
                await autoAdvanceAfterFailure()
                return
            }
            guard playID == id else {
                await cancelAndAwaitStreamingDownloadPreparation(id: preparationID)
                return
            }
            completeStreamingDownloadPreparation(id: preparationID)

            plog("🌊 StreamingDownload firstBuffer: frames=\(firstBuffer.frameLength) sr=\(firstBuffer.format.sampleRate)")
            plog("🌊 Engine diagnostics before play: \(audioEngine.diagnosticInfo())")
            activeDecoderKind = .streaming
            let gate = DecodedBufferGate(
                maxBufferedDuration: Self.decodedAudioLookahead,
                maxBufferedBytes: Self.maxInFlightDecodedBytes,
                maxBufferCount: Self.maxInFlightDecodedBufferCount
            )
            await scheduleTrackedDecodedBuffer(firstBuffer, gate: gate)
            guard !Task.isCancelled, playID == id else {
                await gate.drain()
                return
            }
            installDecodedBufferGate(gate, playID: id)
            hasPreparedLocalPlayback = true
            guard isLocalTransportStartAuthorized(
                playID: id,
                itemID: song.id,
                trigger: "full-download-first-buffer"
            ) else {
                audioEngine.stopPlayback()
                hasPreparedLocalPlayback = false
                isLoading = false
                isPlaying = false
                needsPlaybackRecovery = currentSong?.id == song.id && !isAtTrackEnd
                pendingRecoveryTime = currentTime
                await gate.drain()
                republishNowPlayingSurfaces()
                return
            }
            let didStartPlayback = audioEngine.play()
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

            isPlaying = didStartPlayback
            isLoading = false
            if didStartPlayback {
                clearPendingPlaybackRecovery()
                if shouldRecordPlaybackStart {
                    library?.recordPlayback(of: song.id)
                    ScrobbleService.shared.handlePlaybackStarted(song: song)
                    PlayHistoryStore.shared.beginSession(song: song)
                }
                startTimeUpdater()
            } else {
                showPlaybackError(String(localized: "playback_error_decode"))
                stopTimeUpdater()
            }
            updateNowPlayingInfo()
            updateNowPlayingArtworkIfNeeded()
            updatePlaybackState()

            // Prefetch next song while current one plays
            prefetchNextSong()

            // Decode remaining buffers
            decodingTask = Task { [id, iteratorBox, gate] in
                var lastBuffer: AVAudioPCMBuffer?
                defer { Task { await gate.drain() } }

                // 稳态解码泵整体移出 MainActor: 循环本身不再读主 actor 状态, 归属改由
                // pumpLease 逐块回答; 收尾逻辑仍留在外层这个主 actor Task 里。
                let loop = DecodedBufferSchedulingLoop<AVAudioPCMBuffer, UUID>(
                    playID: id,
                    lease: self.pumpLease,
                    gate: gate,
                    measure: { buffer in
                        DecodedBufferMeasurement(
                            duration: Self.decodedBufferDuration(buffer),
                            byteCount: Self.decodedBufferByteCount(buffer)
                        )
                    },
                    schedule: { [audioEngine = self.audioEngine] buffer, release in
                        audioEngine.scheduleDecodedBuffer(
                            buffer, on: .primary, completionCallbackType: .dataPlayedBack
                        ) { _ in release() }
                    }
                )
                let loopTask = Task.detached(priority: .userInitiated) {
                    await loop.run(next: { try await iteratorBox.next() })
                }
                let outcome = await withTaskCancellationHandler {
                    await loopTask.value
                } onCancel: {
                    loopTask.cancel()
                }

                switch outcome {
                case .cancelled, .lostOwnership:
                    return
                case .completed(let buffer, _):
                    lastBuffer = buffer
                case .failed(let error, let buffer, let scheduledCount):
                    lastBuffer = buffer
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
                    guard !Task.isCancelled else { return }
                    if self.scheduleOutgoingCrossfadeTailBuffer(finalBuffer, playID: id) { return }
                    guard self.playID == id else { return }
                    await self.scheduleDecodedFinalBuffer(finalBuffer, playID: id)
                }
            }
        } catch is CancellationError {
            await cancelAndAwaitStreamingDownloadPreparation(id: preparationID)
            guard !Task.isCancelled, playID == id else { return }
            plog("⚠️ StreamingDownload first-buffer timeout for '\(song.title)' after \(Self.remoteFallbackFirstBufferTimeoutSeconds)s")
            showPlaybackError(String(localized: "playback_error_connection"))
            isLoading = false
            await autoAdvanceAfterFailure()
        } catch {
            await cancelAndAwaitStreamingDownloadPreparation(id: preparationID)
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
            await playWithFallbackDecoder(
                song: song,
                url: url,
                outputFormat: outputFormat,
                playID: id,
                shouldRecordPlaybackStart: shouldRecordPlaybackStart
            )
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
    func makeResolveLengthCallback(for song: Song) -> @Sendable (TimeInterval) -> Void {
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
                if self.applyResolvedDuration(effectiveDuration, toSongID: songID) {
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

    /// Preparation stores `Song` by value, so metadata backfill or the decoder
    /// can update the library without changing the pending handoff snapshot.
    /// Merge the newest usable duration immediately before playback ownership
    /// moves to that snapshot.
    func songRefreshingLatestDuration(_ song: Song) -> Song {
        var refreshed = song
        refreshed.duration = AudioDurationPolicy.playbackHandoffDuration(
            snapshot: song.duration,
            latestLibrary: library?.song(id: song.id)?.duration
        )
        return refreshed
    }

    /// Keep every occurrence of a song in the queue aligned with an
    /// authoritative decoder duration. Returning true tells the caller that
    /// the active Now Playing state also changed and must be republished.
    @discardableResult
    func applyResolvedDuration(
        _ resolved: TimeInterval,
        toSongID songID: String
    ) -> Bool {
        let sanitized = resolved.sanitizedDuration
        guard sanitized > 0 else { return false }

        let updatedCurrentSong = currentSong?.id == songID
        if updatedCurrentSong {
            duration = sanitized
            currentSong?.duration = sanitized
        }
        for index in queueEntries.indices where queueEntries[index].song.id == songID {
            queueEntries[index].song.duration = sanitized
        }
        return updatedCurrentSong
    }

    func decodeStream(
        for song: Song,
        url: URL,
        outputFormat: AVAudioFormat,
        sourceStreamEpoch: UInt64
    ) async -> AudioBufferStream? {
        if url.scheme == SourceManager.cloudStreamingScheme
            || url.scheme == "http"
            || url.scheme == "https" {
            guard CloudPlaybackSource.isStreamEpochTicketCurrent(
                sourceID: song.sourceID,
                ticket: sourceStreamEpoch
            ) else { return nil }
        }
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
                return rawStream.map {
                    transitionPreparedStream($0, for: song, completeFileURL: cached)
                }
            }
            if FileFormatRouter.requiresCompleteLocalFile(song.fileFormat) { return nil }
            guard let manager = sourceManager,
                  let inputSource = try? await manager.makeStreamingInputSource(
                      for: song,
                      cacheEnabled: playbackSettings.audioCacheEnabled,
                      expectedStreamEpoch: sourceStreamEpoch
                  ) else {
                return nil
            }
            rawStream = nativeDecoder.decode(from: inputSource, outputFormat: outputFormat, onResolveSourceLength: onResolveLength)
            return rawStream.map { transitionPreparedStream($0, for: song) }
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
                return rawStream.map {
                    transitionPreparedStream($0, for: song, completeFileURL: cached)
                }
            }
            if FileFormatRouter.requiresCompleteLocalFile(song.fileFormat) { return nil }
            if SourceManager.isTranscodedStreamURL(url), assetReaderDecoder.canDecode(url: url) {
                // 服务端转码流: 渐进 AVAssetReader, 不走已知大小的 Range / 缓存。
                rawStream = assetReaderDecoder.decode(from: url, outputFormat: outputFormat)
                return rawStream.map { transitionPreparedStream($0, for: song) }
            }
            if let inputSource = await makeHTTPStreamingInputSource(
                for: song,
                url: url,
                sourceStreamEpoch: sourceStreamEpoch
            ) {
                rawStream = nativeDecoder.decode(from: inputSource, outputFormat: outputFormat, onResolveSourceLength: onResolveLength)
                return rawStream.map { transitionPreparedStream($0, for: song) }
            }
            return nil
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
        return rawStream.map {
            transitionPreparedStream(
                $0,
                for: song,
                completeFileURL: url.isFileURL ? url : nil
            )
        }
    }

    private func transitionPreparedStream(
        _ stream: AudioBufferStream,
        for song: Song,
        completeFileURL: URL? = nil
    ) -> AudioBufferStream {
        let segmentedStream = segmented(stream, for: song)
        let settings = playbackSettings.snapshot()
        let effectsEnabled = settings.outputMode == .effects
        let smartCrossfade = effectsEnabled
            && settings.crossfadeEnabled
            && settings.crossfadeMode == .smart
        let trimLeading = effectsEnabled
            && (settings.skipLeadingSilenceEnabled || smartCrossfade)
        let trimTrailing = effectsEnabled
            && (settings.skipTrailingSilenceEnabled || smartCrossfade)

        silenceProfiles[song.id] = nil
        resetSmartMixAnalysis(for: song.id)
        if smartCrossfade, let completeFileURL {
            scheduleMusicUnderstandingAnalysis(
                for: song.id,
                completeFileURL: completeFileURL
            )
        }
        guard trimLeading || trimTrailing else { return segmentedStream }

        let songID = song.id
        let maximumTrimDuration = max(12, settings.crossfadeDuration)
        let profileHandler: @Sendable (AudioSilenceProfile) -> Void = { [weak self] profile in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.silenceProfiles.count >= 64,
                   self.silenceProfiles[songID] == nil,
                   let oldestKey = self.silenceProfiles.keys.first {
                    self.silenceProfiles[oldestKey] = nil
                }
                self.silenceProfiles[songID] = profile
                if profile.leadingTrimmedDuration > 0.01
                    || profile.trailingTrimmedDuration > 0.01 {
                    plog(String(
                        format: "Smart transition profile %@: head %.2fs, tail %.2fs, playable %.2fs",
                        String(songID.prefix(8)),
                        profile.leadingTrimmedDuration,
                        profile.trailingTrimmedDuration,
                        profile.playableDuration
                    ))
                }
            }
        }

        guard smartCrossfade else {
            return AudioSilenceStream.trim(
                segmentedStream,
                leading: trimLeading,
                trailing: trimTrailing,
                maximumLeadingDuration: maximumTrimDuration,
                maximumTrailingDuration: maximumTrimDuration,
                onProfile: profileHandler
            )
        }

        return AudioSilenceStream.trimAnalyzingSmartMix(
            segmentedStream,
            leading: trimLeading,
            trailing: trimTrailing,
            maximumLeadingDuration: maximumTrimDuration,
            maximumTrailingDuration: maximumTrimDuration,
            onSmartMixAnalysis: { [weak self] analysis in
                Task { @MainActor [weak self] in
                    self?.storeSmartMixAnalysis(analysis, for: songID)
                }
            },
            onProfile: profileHandler
        )
    }

    private func resetSmartMixAnalysis(for songID: String) {
        smartMixPlatformAnalysisTasks[songID]?.task.cancel()
        smartMixPlatformAnalysisTasks[songID] = nil
        smartMixAnalyses[songID] = nil
    }

    private func storeSmartMixAnalysis(
        _ analysis: SmartMixTrackAnalysis,
        for songID: String
    ) {
        if let existing = smartMixAnalyses[songID] {
            if existing.backend == .musicUnderstanding,
               analysis.backend != .musicUnderstanding {
                return
            }
            if existing.backend == analysis.backend {
                let existingConfidence = existing.tempo?.confidence ?? 0
                let incomingConfidence = analysis.tempo?.confidence ?? 0
                guard analysis.analyzedDuration > existing.analyzedDuration + 0.1
                        || incomingConfidence > existingConfidence else {
                    return
                }
            }
        }
        if smartMixAnalyses.count >= 64,
           smartMixAnalyses[songID] == nil,
           let oldestKey = smartMixAnalyses.keys.first {
            smartMixAnalyses[oldestKey] = nil
        }
        smartMixAnalyses[songID] = analysis
    }

    private func scheduleMusicUnderstandingAnalysis(
        for songID: String,
        completeFileURL: URL
    ) {
        #if canImport(MusicUnderstanding)
        guard completeFileURL.isFileURL else { return }
        if #available(iOS 27.0, macOS 27.0, tvOS 27.0, *) {
            guard SmartMixAnalysisBackendPolicy.preferredBackend(
                operatingSystemMajorVersion: ProcessInfo.processInfo
                    .operatingSystemVersion.majorVersion,
                musicUnderstandingAvailable: true,
                assetAccess: .completeFile
            ) == .musicUnderstanding else { return }

            let taskID = UUID()
            let task = Task { [weak self] in
                defer {
                    if self?.smartMixPlatformAnalysisTasks[songID]?.id == taskID {
                        self?.smartMixPlatformAnalysisTasks[songID] = nil
                    }
                }
                do {
                    let analysis = try await MusicUnderstandingSmartMixAnalyzer.analyze(
                        fileURL: completeFileURL
                    )
                    try Task.checkCancellation()
                    guard let self,
                          self.smartMixPlatformAnalysisTasks[songID]?.id == taskID else {
                        return
                    }
                    self.storeSmartMixAnalysis(analysis, for: songID)
                } catch is CancellationError {
                    return
                } catch {
                    guard !Task.isCancelled else { return }
                    plog(
                        "Music Understanding analysis failed "
                            + "\(String(songID.prefix(8))): \(error.localizedDescription)"
                    )
                }
            }
            smartMixPlatformAnalysisTasks[songID] = SmartMixPlatformAnalysisTask(
                id: taskID,
                task: task
            )
        }
        #endif
    }

    func segmented(
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

    func makeHTTPStreamingInputSource(
        for song: Song,
        url: URL,
        sourceStreamEpoch: UInt64
    ) async -> InputSource? {
        guard song.fileSize > 0,
              url.scheme == "http" || url.scheme == "https",
              CloudPlaybackSource.isStreamEpochTicketCurrent(
                sourceID: song.sourceID,
                ticket: sourceStreamEpoch
              ) else { return nil }

        guard let prepared = await sourceManager?.prepareHTTPStreamingCache(
            for: song,
            prefersPersistentCache: playbackSettings.audioCacheEnabled
        ) else { return nil }
        let cacheURL = prepared.url
        let cacheRelativePath = prepared.relativePath
        let persistentCacheAllowed = prepared.persistOnComplete

        guard CloudPlaybackSource.isStreamEpochTicketCurrent(
            sourceID: song.sourceID,
            ticket: sourceStreamEpoch
        ) else {
            sourceManager?.finalizeStreamingSession(for: song)
            return nil
        }

        let inputSource = CloudPlaybackSource.makeHTTPInputSource(
            song: song,
            url: url,
            totalLength: song.fileSize,
            cacheURL: cacheURL,
            streamEpoch: sourceStreamEpoch,
            persistOnComplete: persistentCacheAllowed,
            cacheRelativePath: cacheRelativePath
        )
        if inputSource == nil {
            sourceManager?.finalizeStreamingSession(for: song)
        }
        return inputSource
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

    func decoderKind(for song: Song, url: URL) async -> DecoderKind {
        if url.scheme == SourceManager.cloudStreamingScheme { return .cloudStream }
        if url.scheme == "http" || url.scheme == "https" {
            if SourceManager.isTranscodedStreamURL(url) { return .assetReader }
            return song.fileSize > 0 ? .httpStream : .streaming
        }
        return await usesFFmpegDecoder(for: song, url: url) ? .ffmpeg : .native
    }

    func usesFFmpegDecoder(for song: Song, url: URL) async -> Bool {
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

    private func probeRemoteWAVPayload(
        for song: Song
    ) async -> RemoteWAVPlaybackPolicy.ProbeOutcome {
        guard let manager = sourceManager else { return .unavailable }
        do {
            let prefix = try await manager.fetchMetadataRange(
                for: song,
                offset: 0,
                length: 256 * 1024
            )
            guard !prefix.isEmpty else { return .unavailable }
            return FFmpegAudioDecoder.dataContainsDTSSync(prefix) ? .dts : .pcm
        } catch {
            plog("Remote WAV content probe unavailable: \(error.localizedDescription)")
            return .unavailable
        }
    }

    func ffmpegCanDecodeOffMain(_ url: URL) async -> Bool {
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

    func prefetchNextSong() {
        synchronizeAppleMusicQueue()
        prefetchTask?.cancel()
        // Prefetch 接下来几首,而不是只 1 首 —— 用户连续 next 切歌时
        // (4-5s/次), 单首 prefetch chain 来不及, 第 2、3 首切到时 partial
        // 还是空, SFB 现拉 1MB chunk 卡 2-3s。数量由 ST-01 设置页控制。
        let nextSongs = nextSongsInQueue(count: playbackSettings.prewarmQueueCount)
        var retainedSongIDs = Set(nextSongs.map(\.id))
        if let currentSong { retainedSongIDs.insert(currentSong.id) }
        sourceManager?.cancelBackgroundAudioCaching(keeping: retainedSongIDs)
        guard !nextSongs.isEmpty else { return }

        prefetchTask = Task {
            for song in nextSongs {
                if Task.isCancelled { return }
                if song.id == currentSong?.id { continue }
                if sourceManager?.cachedURL(for: song) != nil { continue }
                plog("⏩ Prefetching next song: \(song.title)")
                await sourceManager?.cacheForUpcomingPlayback(
                    song: song,
                    cacheEnabled: playbackSettings.audioCacheEnabled
                )
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

        for target in upcomingQueueTraversalTargets(maximumCount: count) {
            let song = queueEntries[target.queueIndex].song
            guard seenIDs.insert(song.id).inserted else { continue }
            result.append(song)
            if result.count == count { break }
        }
        return result
    }

    /// Broad fallback playback. A local file gets FFmpeg first; progressive
    /// remote media uses AVAssetReader because FFmpeg is intentionally opened
    /// only on complete, seekable files in this architecture.
    private func playWithFallbackDecoder(
        song: Song,
        url: URL,
        outputFormat: AVAudioFormat,
        playID id: UUID,
        shouldRecordPlaybackStart: Bool = true
    ) async {
        guard playID == id else { return }
        let useFFmpeg: Bool
        if url.isFileURL {
            useFFmpeg = await ffmpegCanDecodeOffMain(url)
        } else {
            useFFmpeg = false
        }
        guard playID == id else { return }
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
            let gate = DecodedBufferGate(
                maxBufferedDuration: Self.decodedAudioLookahead,
                maxBufferedBytes: Self.maxInFlightDecodedBytes,
                maxBufferCount: Self.maxInFlightDecodedBufferCount
            )
            await scheduleTrackedDecodedBuffer(firstBuffer, gate: gate)
            guard !Task.isCancelled, playID == id else {
                await gate.drain()
                return
            }
            installDecodedBufferGate(gate, playID: id)
            hasPreparedLocalPlayback = true
            guard isLocalTransportStartAuthorized(
                playID: id,
                itemID: song.id,
                trigger: "fallback-first-buffer"
            ) else {
                audioEngine.stopPlayback()
                hasPreparedLocalPlayback = false
                isLoading = false
                isPlaying = false
                needsPlaybackRecovery = currentSong?.id == song.id && !isAtTrackEnd
                pendingRecoveryTime = currentTime
                await gate.drain()
                republishNowPlayingSurfaces()
                return
            }
            let didStartPlayback = audioEngine.play()

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

            isPlaying = didStartPlayback
            isLoading = false
            if didStartPlayback {
                clearPendingPlaybackRecovery()
                if shouldRecordPlaybackStart {
                    library?.recordPlayback(of: song.id)
                    ScrobbleService.shared.handlePlaybackStarted(song: song)
                    PlayHistoryStore.shared.beginSession(song: song)
                }
                startTimeUpdater()
            } else {
                showPlaybackError(String(localized: "playback_error_decode"))
                stopTimeUpdater()
            }
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
            decodingTask = Task { [id, iteratorBox, gate] in
                var lastBuffer: AVAudioPCMBuffer?
                defer { Task { await gate.drain() } }

                // 稳态解码泵整体移出 MainActor: 循环本身不再读主 actor 状态, 归属改由
                // pumpLease 逐块回答; 收尾逻辑仍留在外层这个主 actor Task 里。
                let loop = DecodedBufferSchedulingLoop<AVAudioPCMBuffer, UUID>(
                    playID: id,
                    lease: self.pumpLease,
                    gate: gate,
                    measure: { buffer in
                        DecodedBufferMeasurement(
                            duration: Self.decodedBufferDuration(buffer),
                            byteCount: Self.decodedBufferByteCount(buffer)
                        )
                    },
                    schedule: { [audioEngine = self.audioEngine] buffer, release in
                        audioEngine.scheduleDecodedBuffer(
                            buffer, on: .primary, completionCallbackType: .dataPlayedBack
                        ) { _ in release() }
                    }
                )
                let loopTask = Task.detached(priority: .userInitiated) {
                    await loop.run(next: { try await iteratorBox.next() })
                }
                let outcome = await withTaskCancellationHandler {
                    await loopTask.value
                } onCancel: {
                    loopTask.cancel()
                }

                switch outcome {
                case .cancelled, .lostOwnership:
                    return
                case .completed(let buffer, _):
                    lastBuffer = buffer
                case .failed(let error, let buffer, _):
                    lastBuffer = buffer
                    if !Task.isCancelled {
                        plog("⚠️ \(fallbackName) fallback decode error: \(error.localizedDescription)")
                    }
                }

                if let finalBuffer = lastBuffer {
                    guard !Task.isCancelled else { return }
                    if self.scheduleOutgoingCrossfadeTailBuffer(finalBuffer, playID: id) { return }
                    guard self.playID == id else { return }
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

    func scheduleDecodedFinalBuffer(_ buffer: AVAudioPCMBuffer, playID id: UUID) async {
        guard let advanceTicket = playbackAdvancePolicy.activeTicket else {
            plog("🛡️ final buffer scheduled without auto-advance eligibility")
            audioEngine.scheduleBuffer(buffer)
            return
        }
        guard shouldAttemptGapless(settings: playbackSettings.snapshot()),
              nextSongInQueue() != nil else {
            scheduleLastBuffer(buffer, playID: id, advanceTicket: advanceTicket)
            return
        }

        let transition = GaplessTransitionState(
            queueGeneration: queueGeneration,
            advanceTicket: advanceTicket
        )
        transition.boundary = audioEngine.scheduleBuffer(
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
    func scheduleCrossfadeFinalBuffer(_ buffer: AVAudioPCMBuffer, playID id: UUID) {
        guard let advanceTicket = playbackAdvancePolicy.activeTicket else {
            if crossfadeSwapDone {
                audioEngine.scheduleBuffer(buffer)
            } else {
                audioEngine.scheduleCrossfadeBuffer(buffer)
            }
            return
        }
        let completion: @Sendable (AVAudioPlayerNodeCompletionCallbackType) -> Void = { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.playID == id else { return }
                await self.handleTrackEnd(
                    advanceTicket: advanceTicket,
                    trigger: "crossfade-final"
                )
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

    func scheduleCrossfadeFinalBufferAsFailure(
        _ buffer: AVAudioPCMBuffer,
        playID id: UUID
    ) {
        guard let advanceTicket = playbackAdvancePolicy.activeTicket else {
            if crossfadeSwapDone {
                audioEngine.scheduleBuffer(buffer)
            } else {
                audioEngine.scheduleCrossfadeBuffer(buffer)
            }
            return
        }
        let completion: @Sendable (AVAudioPlayerNodeCompletionCallbackType) -> Void = { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.playID == id else { return }
                await self.autoAdvanceAfterFailure(
                    advanceTicket: advanceTicket,
                    trigger: "crossfade-failure"
                )
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

    func shouldAttemptGapless(settings: PlaybackSettings) -> Bool {
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

    func shouldBypassContinuousAudioTransition(for song: Song?) -> Bool {
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
    private func scheduleLastBuffer(
        _ buffer: AVAudioPCMBuffer,
        playID id: UUID,
        advanceTicket: PlaybackAdvanceTicket
    ) {
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
                await self.handleTrackEnd(
                    advanceTicket: advanceTicket,
                    trigger: "final-buffer"
                )
            }
        }
    }

    /// Schedule the last decoded buffer when the stream errored mid-way.
    /// Lets the buffered audio drain so the user still hears something, but
    /// fires `autoAdvanceAfterFailure` on completion instead of
    /// `handleTrackEnd` — so repeat-one stops on a broken song instead of
    /// looping it, and the play-count isn't bumped for an aborted track.
    private func scheduleLastBufferAsFailure(_ buffer: AVAudioPCMBuffer, playID id: UUID) {
        guard let advanceTicket = playbackAdvancePolicy.activeTicket else {
            audioEngine.scheduleBuffer(buffer)
            return
        }
        audioEngine.scheduleBuffer(
            buffer,
            completionCallbackType: .dataPlayedBack
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.playID == id else { return }
                await self.autoAdvanceAfterFailure(
                    advanceTicket: advanceTicket,
                    trigger: "final-buffer-failure"
                )
            }
        }
    }

    func cancelGaplessTasks() {
        gaplessPreparationTask?.cancel()
        gaplessPreparationTask = nil
        gaplessFollowupTask?.cancel()
        gaplessFollowupTask = nil
    }

    /// Traversal-only changes must discard the prepared successor without
    /// invalidating the current track's completion ticket or rebuilding its
    /// decoder. The next prefetch uses the freshly rebuilt shuffle order.
    private func cancelPreparedQueueSuccessor() {
        cancelGaplessTasks()
        cancelCrossfadeAttempt(finishingCommittedTransition: true)
    }

    /// A changed immediate successor makes any in-flight gapless/crossfade
    /// preparation stale. Advance only the traversal generation: the current
    /// decoder and its automatic-advance ticket remain authoritative until the
    /// track reaches its natural boundary. A committed crossfade already owns
    /// the newly-current song, so reordering the rows after it must not shorten
    /// that audible transition.
    func invalidatePreparedQueueSuccessor() {
        queueGeneration += 1
        cancelGaplessTasks()
        let hasCommittedCurrentCrossfade = committedCrossfade.map {
            crossfadeAttemptID == $0.attemptID && playID == $0.playID
        } ?? false
        if !hasCommittedCurrentCrossfade {
            cancelCrossfadeAttempt()
        }
    }

    func pause() {
        // Record this before route-specific early returns so Apple Music,
        // radio, casting and MV all cancel a pending interruption resume.
        let wasPendingMusicVideo = pendingMusicVideoPlayID == playID
        let wasSeekingMusicVideo = hasMusicVideoSeekActivityEvidence
        registerPauseOrStopIntent()
        if isLiveRadio {
            playID = UUID()
            stopRadioTransport(clearSelection: false)
            updateNowPlayingInfo()
            updatePlaybackState()
            return
        }
        let appleMusic = AppServices.shared.appleMusic
        if isAppleMusicMode
            || activeAppleMusicRequestID != nil
            || appleMusic.activePlaybackRequestID != nil {
            isPlaying = false
            updateNowPlayingInfo()
            updatePlaybackState()
            return
        }
        if isCastingMode {
            setCastingPlayback(shouldPlay: false)
            return
        }
        if isSystemMediaPlaybackActive || wasPendingMusicVideo {
            if isSystemMediaPlaybackActive {
                if !wasSeekingMusicVideo {
                    syncPlaybackProgressFromEngine()
                }
                if isSystemAudioPlaybackActive {
                    systemAudioStartupWatchdog?.cancel()
                    systemAudioStartupWatchdog = nil
                }
                activeSystemMediaPlayer?.pause()
            } else {
                hasPreparedLocalPlayback = false
                needsPlaybackRecovery = false
                pendingRecoveryTime = currentTime
            }
            // AVPlayer pause only stops presentation. The parallel full-file
            // MV cache task otherwise keeps downloading hundreds of MB while
            // the UI visibly says playback is paused. Preserve its .partial
            // file for a later resume/replay, but release network and battery
            // immediately.
            sourceManager?.cancelMusicVideoDownloads(keeping: nil)
            isLoading = false
            isPlaying = false
            updateNowPlayingInfo()
            updatePlaybackState()
            return
        }
        // Align the engine's primary node with currentSong before capturing
        // the pause position during an already-committed fade.
        stopTimeUpdater()
        syncPlaybackProgressFromEngine()
        cancelCrossfadeAttempt(
            finishingCommittedTransition: true,
            completionMode: .preserveCachedProgress
        )
        pendingRecoveryTime = currentTime
        needsPlaybackRecovery = hasPreparedLocalPlayback && currentSong != nil && !isAtTrackEnd
        audioEngine.pauseWithFade()
        isPlaying = false
        updateNowPlayingInfo()
        updatePlaybackState()
    }

    func resume() {
        resumeCurrentPlayback(registeringUserIntent: true)
    }

    private func resumeCurrentPlayback(registeringUserIntent: Bool) {
        // Repeated Play while the same MV request is still resolving is an
        // idempotent no-op. Clearing its pending token here would strand the
        // visible item in loading state with no resolver left to finish it.
        if registeringUserIntent,
           isLoading,
           pendingMusicVideoPlayID == playID {
            return
        }
        if registeringUserIntent {
            registerPlayIntent()
        }
        if isLiveRadio {
            guard let station = currentRadioStation else { return }
            let stations = radioStationOrder
            let resumeGeneration = playbackAdvancePolicy.generation
            Task { @MainActor [weak self] in
                guard let self,
                      self.playbackAdvancePolicy.generation == resumeGeneration,
                      self.interruptionResumePolicy.playbackIsIntended,
                      self.currentRadioStation?.id == station.id else { return }
                await self.play(station: station, within: stations)
            }
            return
        }
        if isAppleMusicMode {
            guard let song = currentSong else { return }
            let appleMusic = AppServices.shared.appleMusic
            if let requestID = appleMusic.activePlaybackRequestID,
               appleMusic.playbackPhase(for: requestID) == .started {
                _ = appleMusic.resumeAppleMusic()
            } else {
                // A restored item or a failed/pending request has no resumable
                // MusicKit generation. Recreate playback first, then apply the
                // saved position when the mirror reports that it started.
                pendingAppleMusicRestoredPosition = (song.id, currentTime)
                let resumeGeneration = playbackAdvancePolicy.generation
                Task { @MainActor [weak self] in
                    guard let self,
                          self.playbackAdvancePolicy.generation == resumeGeneration,
                          self.interruptionResumePolicy.playbackIsIntended,
                          self.currentSong?.id == song.id else { return }
                    await self.play(song: song, caller: "RestoredAppleMusic")
                }
            }
            return
        }
        if isCastingMode {
            setCastingPlayback(shouldPlay: true)
            return
        }
        guard !isLoading, let song = currentSong else { return }
        if isMusicVideoModeEnabled,
           canPlayMusicVideo,
           !isSystemMediaPlaybackActive {
            let resumeTime = currentTime
            let resumeGeneration = playbackAdvancePolicy.generation
            Task { @MainActor [weak self] in
                guard let self,
                      self.playbackAdvancePolicy.generation == resumeGeneration,
                      self.interruptionResumePolicy.playbackIsIntended,
                      self.currentSong?.id == song.id else { return }
                await self.play(song: song)
                if resumeTime > 0 {
                    await self.waitForPlaybackPipelineSettled()
                    guard self.interruptionResumePolicy.playbackIsIntended,
                          self.currentSong?.id == song.id else { return }
                    self.seek(to: resumeTime, startPlaying: true)
                }
            }
            return
        }
        if isSystemMediaPlaybackActive {
            _ = beginAutomaticAdvanceTransport(
                itemID: song.id,
                reason: registeringUserIntent ? "music-video-manual-resume" : "music-video-system-resume"
            )
            guard let player = activeSystemMediaPlayer, let id = playID else { return }
            configureMusicVideoObservers(for: player, playID: id)
            _ = AudioSessionManager.shared.activatePlaybackSession()
            player.play()
            if isSystemAudioPlaybackActive, !systemAudioPlaybackDidStart {
                isLoading = true
                isPlaying = false
                armSystemAudioStartupWatchdog(player: player, playID: id)
            } else {
                isLoading = false
                isPlaying = true
                clearPendingPlaybackRecovery()
            }
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
            let resumeGeneration = playbackAdvancePolicy.generation
            Task { @MainActor [weak self] in
                guard let self,
                      self.playbackAdvancePolicy.generation == resumeGeneration,
                      self.interruptionResumePolicy.playbackIsIntended,
                      self.currentSong?.id == song.id else { return }
                await self.play(song: song)
            }
            return
        case .recoverFromInterruption:
            seek(
                to: pendingRecoveryTime,
                startPlaying: true,
                isRecovery: true,
                isColdSessionRestore: pendingRecoveryIsColdSessionRestore
            )
            return
        case .resumePreparedAudio:
            let preparedTicket = playbackAdvancePolicy.activeTicket
            guard preparedTicket?.itemID == song.id,
                  preparedTicket == localPipelineAdvanceTicket else {
                // The buffers may still be playable, but their terminal
                // callbacks belong to an invalidated ticket. Rebuild rather
                // than minting a ticket those callbacks never captured.
                seek(to: currentTime, startPlaying: true, isRecovery: true)
                return
            }
        }
        _ = AudioSessionManager.shared.activatePlaybackSession()
        let didResume = audioEngine.resumeWithFade()
        isPlaying = didResume
        if didResume {
            syncPlaybackProgressFromEngine()
            startTimeUpdater()
        } else {
            stopTimeUpdater()
            showPlaybackError(String(localized: "playback_error_decode"))
        }
        updateNowPlayingInfo()
        updatePlaybackState()
    }

    private var seekTimeOffset: TimeInterval = 0
    @ObservationIgnored var seekTask: Task<Void, Never>?

    /// 进度 timer 间隔 (秒)。同时作为 scrobble 的真实收听增量 —— 见下方 handleProgressTick。
    static let timeUpdateInterval: TimeInterval = 0.5

    // MARK: - Now Playing Info

    #if os(iOS)
    @ObservationIgnored private var systemLyricsLoadTask: Task<Void, Never>?
    @ObservationIgnored private var systemLyricsRetryTask: Task<Void, Never>?
    @ObservationIgnored private var systemLyricsLoadGeneration: UInt64 = 0
    @ObservationIgnored private var systemLyricsEmptyResultCount = 0
    @ObservationIgnored private var systemLyricsSongID: String?
    @ObservationIgnored private var systemLyrics: [LyricLine] = []
    /// `systemLyrics` 里能驱动锁屏行的子集。锁屏每 0.5s 刷一次,
    /// 过滤只跟歌词文档有关, 所以随 `systemLyrics` 一起缓存。
    @ObservationIgnored private var systemSynchronizedLyrics: [LyricLine] = []
    @ObservationIgnored var lastPublishedLockScreenLyricsPresentation:
        NowPlayingLyricsMetadataPresentation?
    /// 最近一次把歌词行发布给 MediaRemote 的时刻, 用于 1 秒限流。
    @ObservationIgnored var lastLockScreenLyricsPublishAt: Date?
    /// 限流窗口内到达的那一行: 不丢弃, 窗口结束后补发(通常 0.5 秒的时钟
    /// tick 会先到并发出去)。
    @ObservationIgnored var pendingLockScreenLyricsPublish = false
    @ObservationIgnored private var lockScreenLyricsCatchUpTask: Task<Void, Never>?
    /// 标识当前补发任务的归属。任务句柄本身无法在闭包里和自己比较, 用这个
    /// 单调递增的令牌代替身份比较: 只有仍然是最新一次调度的任务才可以清空
    /// 句柄, 否则被取消的旧任务会抹掉后继任务的句柄。
    @ObservationIgnored private var lockScreenLyricsCatchUpToken: UInt64 = 0
    @ObservationIgnored private var lastPublishedWidgetLyricsSignature: String?
    @ObservationIgnored private var lyricsWidgetConfigurationRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var lastLyricsWidgetConfigurationRefreshAt = Date.distantPast
    @ObservationIgnored private var hasInstalledLyricsWidgetSurface = false

    private var widgetLyricsSharingEnabled: Bool {
        WidgetSettings.syncEnabled()
            && WidgetSettings.widgetEnabled(PrimuseConstants.widgetLyricsEnabledKey)
            && WidgetSettings.sharedDataScope().includesLyrics
    }

    private var shouldPublishWidgetLyrics: Bool {
        widgetLyricsSharingEnabled && hasInstalledLyricsWidgetSurface
    }

    private var shouldLoadLyricsForSystemSurfaces: Bool {
        #if DEBUG
        if LyricsLiveActivityService.isProbeEnabled { return true }
        #endif
        return playbackSettings.lockScreenLyricsEnabled || shouldPublishWidgetLyrics
    }

    private func observeLockScreenLyricsSetting() {
        withObservationTracking {
            _ = playbackSettings.lockScreenLyricsEnabled
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.resetSystemLyricsState()
                self.updateNowPlayingInfo()
                self.loadLyricsForSystemSurfacesIfNeeded(for: self.currentSong)
                self.observeLockScreenLyricsSetting()
            }
        }
    }

    private func prepareLyricsForSystemSurfaces(previousSong: Song?) {
        let previousIdentity = previousSong.map { ($0.id, $0.lyricsFileName) }
        let currentIdentity = currentSong.map { ($0.id, $0.lyricsFileName) }
        guard previousIdentity?.0 != currentIdentity?.0
                || previousIdentity?.1 != currentIdentity?.1 else { return }

        resetSystemLyricsState()
        refreshInstalledLyricsWidgetDemand()
        loadLyricsForSystemSurfacesIfNeeded(for: currentSong)
    }

    /// Lyrics loading can reach a remote sidecar or metadata provider. Only do
    /// that work for a widget when the user has actually placed a lyrics-capable
    /// family on the Home Screen; lock-screen lyrics remains independently gated.
    func refreshInstalledLyricsWidgetDemand(force: Bool = false) {
        guard widgetLyricsSharingEnabled else {
            clearWidgetLyricsSnapshotIfNeeded()
            if !shouldLoadLyricsForSystemSurfaces {
                resetSystemLyricsState()
            }
            return
        }
        guard lyricsWidgetConfigurationRefreshTask == nil else { return }
        let now = Date()
        guard force || now.timeIntervalSince(lastLyricsWidgetConfigurationRefreshAt) >= 15 else {
            return
        }

        lyricsWidgetConfigurationRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.lyricsWidgetConfigurationRefreshTask = nil
                self.lastLyricsWidgetConfigurationRefreshAt = Date()
            }

            guard let configurations = try? await WidgetCenter.shared.currentConfigurations()
            else { return }
            let isInstalled = configurations.contains { configuration in
                configuration.kind == "LyricsWidget"
                    || (configuration.kind == "NowPlayingWidget"
                        && configuration.family == .systemLarge)
            }
            guard isInstalled != self.hasInstalledLyricsWidgetSurface else {
                if isInstalled,
                   self.systemLyricsLoadTask == nil,
                   self.systemLyricsSongID != self.currentSong?.id {
                    self.loadLyricsForSystemSurfacesIfNeeded(for: self.currentSong)
                }
                return
            }

            self.hasInstalledLyricsWidgetSurface = isInstalled
            if isInstalled {
                if self.systemLyricsLoadTask == nil {
                    self.loadLyricsForSystemSurfacesIfNeeded(for: self.currentSong)
                }
            } else {
                self.clearWidgetLyricsSnapshotIfNeeded()
                if !self.shouldLoadLyricsForSystemSurfaces {
                    self.resetSystemLyricsState()
                }
            }
        }
    }

    private func resetSystemLyricsState() {
        systemLyricsLoadTask?.cancel()
        systemLyricsLoadTask = nil
        systemLyricsRetryTask?.cancel()
        systemLyricsRetryTask = nil
        systemLyricsLoadGeneration &+= 1
        systemLyricsEmptyResultCount = 0
        systemLyricsSongID = nil
        systemLyrics = []
        systemSynchronizedLyrics = []
        lastPublishedLockScreenLyricsPresentation = nil
        lockScreenLyricsCatchUpTask?.cancel()
        lockScreenLyricsCatchUpTask = nil
        lockScreenLyricsCatchUpToken &+= 1
        pendingLockScreenLyricsPublish = false
        clearWidgetLyricsSnapshotIfNeeded()
        publishLyricsActivityProbe()
    }

    private func loadLyricsForSystemSurfacesIfNeeded(for song: Song?) {
        guard shouldLoadLyricsForSystemSurfaces,
              !isLiveRadio,
              let song else { return }
        guard systemLyricsLoadTask == nil,
              systemLyricsRetryTask == nil else { return }

        let expectedSongID = song.id
        let expectedGeneration = systemLyricsLoadGeneration
        let capturedSourceManager = sourceManager
        systemLyricsLoadTask = Task { @MainActor [weak self, capturedSourceManager] in
            let lyrics: [LyricLine]
            if song.sourceID == AppleMusicLibraryService.systemSourceID {
                if let cached = await MetadataAssetStore.shared.cachedLyrics(forSongID: song.id) {
                    lyrics = cached
                } else if let fetched = try? await AppServices.shared.appleMusicLibrary
                    .fetchLyrics(forAmID: song.filePath), !fetched.isEmpty {
                    _ = await MetadataAssetStore.shared.cacheLyrics(
                        fetched,
                        forSongID: song.id,
                        force: true
                    )
                    lyrics = fetched
                } else {
                    lyrics = []
                }
            } else if let capturedSourceManager {
                lyrics = await LyricsLoader.load(
                    for: song,
                    sourceManager: capturedSourceManager
                )
            } else {
                lyrics = []
            }
            guard !Task.isCancelled,
                  let self,
                  self.systemLyricsLoadGeneration == expectedGeneration,
                  self.shouldLoadLyricsForSystemSurfaces,
                  !self.isLiveRadio,
                  self.currentSong?.id == expectedSongID else { return }

            self.systemLyricsLoadTask = nil
            self.systemLyricsSongID = expectedSongID
            self.systemLyrics = lyrics
            self.systemSynchronizedLyrics = NowPlayingLyricsMetadataPolicy
                .synchronizedLines(lyrics)
            if lyrics.isEmpty {
                self.scheduleSystemLyricsRetryIfNeeded(
                    forSongID: expectedSongID,
                    generation: expectedGeneration
                )
            } else {
                self.systemLyricsEmptyResultCount = 0
            }
            self.publishLockScreenLyricsIfNeeded()
            self.publishWidgetLyricsIfNeeded()
        }
    }

    private func scheduleSystemLyricsRetryIfNeeded(
        forSongID songID: String,
        generation: UInt64
    ) {
        systemLyricsEmptyResultCount += 1
        guard let delay = NowPlayingLyricsLoadRetryPolicy.delay(
            afterEmptyResultCount: systemLyricsEmptyResultCount,
            hasDemand: shouldLoadLyricsForSystemSurfaces,
            isLiveStream: isLiveRadio
        ) else { return }

        systemLyricsRetryTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard let self,
                  self.systemLyricsLoadGeneration == generation,
                  self.shouldLoadLyricsForSystemSurfaces,
                  !self.isLiveRadio,
                  self.currentSong?.id == songID else { return }
            self.systemLyricsRetryTask = nil
            self.systemLyricsSongID = nil
            self.systemLyrics = []
            self.systemSynchronizedLyrics = []
            self.loadLyricsForSystemSurfacesIfNeeded(for: self.currentSong)
        }
    }

    func retryEmptySystemLyricsAfterForegroundingIfNeeded() {
        guard shouldLoadLyricsForSystemSurfaces,
              !isLiveRadio,
              systemLyricsLoadTask == nil,
              systemLyricsRetryTask == nil,
              let song = currentSong,
              systemLyricsSongID == song.id,
              systemLyrics.isEmpty else { return }

        systemLyricsEmptyResultCount = 0
        systemLyricsSongID = nil
        loadLyricsForSystemSurfacesIfNeeded(for: song)
    }

    func lockScreenLyricsPresentation() -> NowPlayingLyricsMetadataPresentation {
        guard let song = currentSong else {
            return NowPlayingLyricsMetadataPresentation(title: "", artist: "", lyricLineID: nil)
        }
        let lyrics = systemLyricsSongID == song.id ? systemSynchronizedLyrics : []
        return NowPlayingLyricsMetadataPolicy.presentation(
            canonicalTitle: song.title,
            artistName: displayedArtistName(for: song),
            synchronizedLyrics: lyrics,
            playbackTime: currentTime,
            isEnabled: playbackSettings.lockScreenLyricsEnabled,
            isLiveStream: isLiveRadio,
            prefersStableTitle: shouldForceAudioOnly
        )
    }

    private func publishLockScreenLyricsIfNeeded() {
        publishLyricsActivityProbe()
        guard playbackSettings.lockScreenLyricsEnabled,
              !isLiveRadio,
              systemLyricsSongID == currentSong?.id,
              !systemLyrics.isEmpty else { return }

        let presentation = lockScreenLyricsPresentation()
        let lineChanged = presentation != lastPublishedLockScreenLyricsPresentation
        guard lineChanged || pendingLockScreenLyricsPublish else { return }

        // 每次 nowPlayingInfo 赋值都是主线程上的同步 XPC, 歌词行 2~6 秒一换
        // 时会和滚动抢主线程。限流到 1 秒一次, 被压住的那一行随后补发。
        let now = Date()
        guard NowPlayingLyricsPublishPolicy.shouldPublish(
            lastPublishedAt: lastLockScreenLyricsPublishAt,
            now: now,
            lineChanged: true
        ) else {
            pendingLockScreenLyricsPublish = true
            scheduleLockScreenLyricsCatchUp(
                after: NowPlayingLyricsPublishPolicy.delayUntilNextPublish(
                    lastPublishedAt: lastLockScreenLyricsPublishAt,
                    now: now
                )
            )
            return
        }
        updateNowPlayingInfo(lyricsLineOnly: true)
    }

    /// 播放时 0.5 秒的时钟 tick 通常会先把补发做掉; 暂停、路由切换等没有
    /// tick 的场景靠这个一次性任务保证当前歌词行仍然会被发布出去。
    private func scheduleLockScreenLyricsCatchUp(after delay: TimeInterval) {
        guard lockScreenLyricsCatchUpTask == nil else { return }
        lockScreenLyricsCatchUpToken &+= 1
        let token = lockScreenLyricsCatchUpToken
        lockScreenLyricsCatchUpTask = Task { @MainActor [weak self] in
            if delay > 0 {
                try? await Task.sleep(for: .seconds(delay))
            }
            guard let self else { return }
            // 取消后的 sleep 会立刻返回, 但这一段要等到之后的某个主 actor
            // 轮次才执行; 那时句柄可能已经属于新一次调度, 清空它会让单飞
            // 不变量失效并允许重复补发。
            guard self.lockScreenLyricsCatchUpToken == token else { return }
            self.lockScreenLyricsCatchUpTask = nil
            guard !Task.isCancelled else { return }
            self.publishLockScreenLyricsIfNeeded()
        }
    }

    func publishLyricsActivityProbe() {
        #if DEBUG
        guard LyricsLiveActivityService.isProbeEnabled else { return }
        guard let song = currentSong, !isLiveRadio, !isAtTrackEnd else {
            LyricsLiveActivityService.shared.publish(nil)
            return
        }
        let presentation = NowPlayingLyricsMetadataPolicy.presentation(
            canonicalTitle: song.title,
            artistName: displayedArtistName(for: song),
            lyrics: systemLyricsSongID == song.id ? systemLyrics : [],
            playbackTime: currentTime,
            isEnabled: true,
            isLiveStream: false
        )
        LyricsLiveActivityService.shared.publish(.init(
            songID: String(song.id.prefix(120)),
            title: String(song.title.prefix(120)),
            artist: String((displayedArtistName(for: song) ?? "").prefix(120)),
            lyric: presentation.lyricLineID == nil ? "" : String(presentation.title.prefix(200)),
            isPlaying: isPlaybackActuallyActive
        ))
        #endif
    }

    private func observeLockScreenLyricsChanges() {
        let center = NotificationCenter.default
        center.addObserver(
            forName: .primuseLyricsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let songID = notification.object as? String else { return }
            Task { @MainActor [weak self] in
                self?.reloadSystemLyricsIfCurrent(songID: songID)
            }
        }
        center.addObserver(
            forName: .primuseLyricsDidCache,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let songID = notification.userInfo?["songID"] as? String else { return }
            Task { @MainActor [weak self] in
                self?.reloadSystemLyricsIfCurrent(songID: songID)
            }
        }
    }

    private func reloadSystemLyricsIfCurrent(songID: String) {
        guard shouldLoadLyricsForSystemSurfaces,
              currentSong?.id == songID else { return }
        resetSystemLyricsState()
        updateNowPlayingInfo()
        loadLyricsForSystemSurfacesIfNeeded(for: currentSong)
    }

    func publishWidgetLyricsIfNeeded(coverImageName: String? = nil) {
        guard shouldPublishWidgetLyrics, !isLiveRadio else {
            clearWidgetLyricsSnapshotIfNeeded()
            return
        }
        guard let song = currentSong,
              systemLyricsSongID == song.id,
              !systemLyrics.isEmpty else {
            clearWidgetLyricsSnapshotIfNeeded()
            return
        }

        let position = max(0, currentTime)
        let widgetLines = systemLyrics.map {
            WidgetLyricLine(time: $0.timestamp, text: $0.text)
        }
        let anchor = WidgetLyricsPresentationPolicy.anchorIndex(
            for: position,
            in: widgetLines
        )
        let playback = PlaybackState.load()
        let resolvedCoverName = coverImageName
            ?? (playback?.currentSongID == song.id ? playback?.coverImageName : nil)
        let isActivelyPlaying = isPlaybackActuallyActive
        let direction = LyricWritingDirectionPolicy.resolve(in: systemLyrics)
        let signature = [
            song.id,
            song.title,
            displayedArtistName(for: song) ?? "",
            resolvedCoverName ?? "",
            String(anchor),
            String((position * 2).rounded().finiteInt()),
            isActivelyPlaying ? "1" : "0",
            direction.rawValue,
            String(widgetLines.count),
            String(widgetLines.last?.time ?? 0),
        ].joined(separator: "|")
        guard signature != lastPublishedWidgetLyricsSignature else { return }

        LyricsSnapshot(
            songID: song.id,
            title: song.title,
            artist: displayedArtistName(for: song) ?? "",
            coverImageName: resolvedCoverName,
            lines: widgetLines,
            anchorIndex: anchor,
            playbackPosition: position,
            isPlaying: isActivelyPlaying,
            writingDirection: direction
        ).save()
        lastPublishedWidgetLyricsSignature = signature
        WidgetCenter.shared.reloadTimelines(ofKind: "LyricsWidget")
        WidgetCenter.shared.reloadTimelines(ofKind: "NowPlayingWidget")
    }

    private func clearWidgetLyricsSnapshotIfNeeded() {
        lastPublishedWidgetLyricsSignature = nil
        guard LyricsSnapshot.load() != nil else { return }
        LyricsSnapshot.clear()
        WidgetCenter.shared.reloadTimelines(ofKind: "LyricsWidget")
        WidgetCenter.shared.reloadTimelines(ofKind: "NowPlayingWidget")
    }

    private func observeLikedSongChanges() {
        NotificationCenter.default.addObserver(
            forName: .primusePlaylistsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let ids = notification.userInfo?["ids"] as? [String]
            guard ids?.contains(MusicLibrary.likedSongsPlaylistID) ?? true else { return }
            Task { @MainActor [weak self] in
                self?.republishNowPlayingSurfaces()
            }
        }
    }
    #endif

    /// Tracks which song last started an artwork lookup to avoid redundant IO.
    var lastArtworkSongID: String?

    /// Identifies the song that owns the artwork currently published to the
    /// system. It must match `currentSong` before metadata refreshes can carry
    /// that image forward.
    var publishedArtworkSongID: String?

    /// 解码并降采样后的系统封面内存缓存(songID → artwork)。蓝牙 AVRCP
    /// 车机只在曲目元数据变化的那一刻采样一次封面, 异步补发的图不会被
    /// 重新拉取; 只有切歌后的第一份 nowPlayingInfo 快照就带上新歌封面,
    /// 车机才能显示。命中该缓存即可同步做到, 冷路径仍走异步加载回填。
    let nowPlayingArtworkCache: NSCache<NSString, MPMediaItemArtwork> = {
        let cache = NSCache<NSString, MPMediaItemArtwork>()
        cache.countLimit = 8
        cache.totalCostLimit = 24 * 1_024 * 1_024
        return cache
    }()

    /// 最近一次发布给 MediaRemote 的完整 nowPlayingInfo 快照及其身份。歌词
    /// 行推进时直接在这份字典上改标题/副标题与进度, 其余键(尤其是封面)原样
    /// 复用, 避免每行都重建字典并让系统重新序列化封面位图。
    @ObservationIgnored var cachedNowPlayingInfo: [String: Any]?
    @ObservationIgnored var cachedNowPlayingInfoKey: NowPlayingInfoSnapshotKey?
    /// 快照里当前携带的封面对象。它换成另一个实例时封面版本号才前进。
    @ObservationIgnored var cachedNowPlayingArtwork: MPMediaItemArtwork?
    @ObservationIgnored var nowPlayingArtworkRevision: Int = 0

    /// 正在预取封面的 songID, 防止对同一首歌重复启动预取任务。
    @ObservationIgnored var prefetchingArtworkSongID: String?

    /// 每首歌当前有效的系统封面加载票据。同曲重新刮削可能与先前的远程封面
    /// 请求重叠;只有最后一次请求可以回写内存缓存和 Now Playing,避免旧任务
    /// 在新封面发布后又把车机显示回滚。
    @ObservationIgnored var nowPlayingArtworkLoadTokens: [String: UUID] = [:]
    @ObservationIgnored var nowPlayingArtworkLoadTask: Task<Void, Never>?
    @ObservationIgnored var nowPlayingArtworkPrefetchTask: Task<Void, Never>?

    /// 单调递增的封面刷新 token。当刮削回写完成、cache 失效但 coverArtFileName
    /// 字符串可能没变（hash deterministic）时, view 上的 onChange(coverRef) 不会
    /// 触发 reload, @State image 卡在旧 UIImage。CachedArtworkView 监听这个
    /// token, 任意 bump 都能强制三个封面位重新走 loadImage。
    var coverRevision: Int = 0

    @ObservationIgnored var lastWrittenRemoteCommandAvailability:
        RemoteCommandAvailability?

    /// Tracks the last songID for which we wrote a widget cover, to avoid redundant writes.
    var lastWidgetCoverSongID: String?
    /// Coalesces repeated WidgetKit reload requests with identical content.
    var lastWidgetTimelineSignature: String?
}
