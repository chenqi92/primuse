import CryptoKit
import Foundation
import PrimuseKit
#if os(iOS)
import UIKit
#endif

/// Fills in metadata for songs that were added by ConnectorScanner in
/// "bare-song" mode (cloud sources only download a few hundred KB during
/// scan). This runs continuously in the background, fetching just the file
/// header via HTTP Range, extracting tags, and replacing the song in the
/// library with a fully-populated copy.
///
/// Lifecycle:
/// - A real library/source mutation marks the durable queue dirty. iOS runs it
///   primarily in background/BGProcessing windows. A completed foreground
///   source scan gets one small serial pass so new rows can surface metadata
///   without restarting whole-library foreground maintenance.
/// - The standard worker can use a small bounded amount of concurrency. iOS
///   background profiles deliberately trade throughput for smooth playback.
/// - Failed songs (corrupt / missing / decoder rejected) are recorded so we
///   don't retry them every launch. Successful ones are replaced in the
///   library and persist via `MusicLibrary.persistSnapshot()`.
@MainActor
@Observable
final class MetadataBackfillService {
    /// Bytes to fetch from the start of an audio file. Big enough to cover
    /// embedded artwork + ID3v2 + FLAC Vorbis comments + most M4A `moov`
    /// headers. If a particular file's metadata isn't in this slice we may
    /// need to retry with a tail-Range fetch (M4A with trailing moov).
    private static let headBytes: Int64 = 256 * 1024
    /// A declared ID3 boundary may place both artwork and the first MPEG frame
    /// beyond `headBytes`. Expansion stays capped so one outlier cannot turn a
    /// library backfill into full-file downloads.
    private static let maxMetadataHeadBytes = RemoteMetadataReadPolicy.maximumHeadByteCount
    private static let defaultMP3Bitrate = RemoteMetadataReadPolicy.defaultMP3BitRateKbps

    private static let fallbackTailBytes: Int64 = 256 * 1024
    private static let isoBaseMediaExtensions: Set<String> = ["m4a", "m4b", "mp4", "m4v", "mov", "alac"]

    /// Persisted IDs whose bytes were read successfully but the expected
    /// metadata parser still produced no usable details.
    private var failedSongIDs: Set<String> = []

    /// Persisted IDs that remain playable through a stream descriptor or the
    /// complete-file decoder even though bounded header reads cannot determine
    /// duration. This suppresses only the duration leg; title/artwork inspection
    /// remains independently eligible.
    private var incompleteSongIDs: Set<String> = []

    /// Persisted IDs whose source object/path could not be read. They are not
    /// parser failures and surface as "check source" until an explicit retry,
    /// source availability change, or content-change notification clears them.
    private var sourceIssueSongIDs: Set<String> = []

    /// Songs that parsed fine (have a usable duration) but yielded no
    /// extractable embedded artwork. Kept SEPARATE from `failedSongIDs`:
    /// a missing cover must not mark a song permanently failed (that dropped
    /// its duration update at flush and stuck it bare). These songs stay
    /// playable & recoverable; we only stop re-fetching them *for artwork*.
    private var artworkGivenUpIDs: Set<String> = []

    /// Songs whose embedded title has been checked under the metadata-title
    /// policy. Older builds intentionally kept the filename even after parsing
    /// tags, so every backfillable remote song needs one successful pass after
    /// upgrading. Persisting the IDs makes this a one-time repair rather than a
    /// Range request on every launch.
    private var titleCheckedIDs: Set<String> = []

    /// Songs whose album-artist field has been inspected, including files that
    /// legitimately contain neither an album artist nor a track artist. Absence
    /// is a completed result; without this independent marker those rows remain
    /// eligible forever whenever they have an album title.
    private var albumArtistCheckedIDs: Set<String> = []

    /// Songs whose track-artist field has been inspected. Track artist is
    /// independent from duration and album artist: a valid FLAC STREAMINFO
    /// block can complete duration while a later Vorbis-comment block has not
    /// yet been read. Persisting absence prevents an artist-less file from
    /// looping forever after one complete bounded inspection.
    private var artistCheckedIDs: Set<String> = []

    /// Consecutive transient failure count per song ID. Counts are persisted so
    /// relaunching the app or changing networks cannot reset the automatic retry
    /// budget and keep rereading the same permanently unreachable object.
    private var transientFailureCounts: [String: Int] = [:]
    /// Source-wide authentication/connection failures use a separate budget so
    /// a 10k-song source cannot evade the cap by failing on a different row at
    /// every launch.
    private var sourceTransientFailureCounts: [String: Int] = [:]

    /// Songs parked until another usable network path is observed. Every real
    /// transient failure parks immediately instead of being retried five times
    /// back-to-back in one worker loop.
    private var sessionGivenUpIDs: Set<String> = []
    private var sessionNetworkParkedIDs: Set<String> = []
    /// Repeated snapshots indicate a state-application problem rather than a
    /// transport problem and must not be unparked by a network transition.
    private var sessionStallParkedIDs: Set<String> = []

    /// Persisted marker for songs that still need another attempt after a
    /// transient transport failure. Unlike `sessionGivenUpIDs`, this set does
    /// not suppress queueing: it survives relaunch only so the UI can explain
    /// that these requests are retries rather than a new scan. A successful or
    /// terminal inspection removes the marker.
    private var deferredRetrySongIDs: Set<String> = []

    /// UserDefaults key for "only run backfill on Wi-Fi". Default true.
    /// User-facing toggle lives in CloudSyncSettingsView.
    static let wifiOnlyDefaultsKey = "primuse.cloudScanWifiOnly"

    /// Whether the cellular opt-in alert is currently visible. This is kept
    /// separate from `isWaitingForWiFi`: dismissing the alert must not make a
    /// deferred queue look active again.
    private(set) var pausedForCellular: Bool = false
    /// User opted into cellular backfill for this session only (not persisted).
    private var cellularAllowedThisSession = false
    /// User dismissed the cellular prompt this session — don't re-prompt
    /// automatically until next launch.
    private var cellularPromptDismissedThisSession = false

    /// Publish prompt visibility only on a real state transition. During a
    /// connector scan `musicLibrary.songs.count` changes repeatedly and each
    /// change calls `refreshQueue()` → `start()`. Assigning observable `true`
    /// again for every batch makes SwiftUI treat one cellular pause as many
    /// alert presentation events even though there is only one source.
    private func setCellularPromptPresented(_ presented: Bool) {
        guard pausedForCellular != presented else { return }
        pausedForCellular = presented
        if presented {
            #if os(iOS)
            AppAlertCoordinator.shared.enqueue(.cellularBackfill)
            #endif
        } else {
            AppAlertCoordinator.shared.cancel(.cellularBackfill)
        }
    }

    private let library: MusicLibrary
    private let sourceManager: SourceManager
    private let backfillableSourceIDs: () -> Set<String>
    private let metadataService = MetadataService()
    private let failedURL: URL
    private let incompleteURL: URL
    private let sourceIssueURL: URL
    private let artworkGivenUpURL: URL
    private let titleCheckedURL: URL
    private let albumArtistCheckedURL: URL
    private let artistCheckedURL: URL
    private let deferredRetryURL: URL
    private let retryCountsURL: URL
    private let sourceRetryCountsURL: URL
    private let queueStateURL: URL
    private nonisolated static let queueDirtyDefaultsKey =
        "primuse.metadataBackfill.queueDirty.v1"
    private nonisolated static let queueMutationGenerationDefaultsKey =
        "primuse.metadataBackfill.queueMutationGeneration.v1"

    private struct QueueState: Codable, Equatable, Sendable {
        let needsRefresh: Bool
        let reconciledGeneration: Int
        let remainingCount: Int
        let failedCount: Int
        let deferredRetryCount: Int
        let statusCount: Int
        let remainingCountBySourceID: [String: Int]
        let deferredRetryCountBySourceID: [String: Int]
        let statusCountBySourceID: [String: Int]
    }

    /// Songs currently being processed (for UI / cancellation).
    private(set) var pendingCount: Int = 0
    private(set) var processedCount: Int = 0
    private(set) var isRunning: Bool = false
    /// True while eligible work exists but the Wi-Fi-only gate prevents new
    /// metadata reads. Unlike the alert state, this remains true after the user
    /// chooses to keep waiting for Wi-Fi.
    private(set) var isWaitingForWiFi: Bool = false
    /// Cached in one library pass and consumed by all source cards. The old
    /// implementation filtered the complete song array once per card on every
    /// SwiftUI body update, multiplying work by source count during scrolling.
    private(set) var cachedRemainingCount: Int = 0
    private(set) var cachedFailedCount: Int = 0
    private(set) var remainingCountBySourceID: [String: Int] = [:]
    private(set) var cachedDeferredRetryCount: Int = 0
    private(set) var deferredRetryCountBySourceID: [String: Int] = [:]
    private(set) var cachedStatusCount: Int = 0
    private(set) var statusCountBySourceID: [String: Int] = [:]
    /// Sources represented by the worker's current fixed snapshot. Per-source
    /// cards use this rather than the global worker flag, so an idle source does
    /// not show a spinner while another provider is being processed.
    private(set) var activeSourceIDs: Set<String> = []
    private var lastRemainingCountRefreshAt = Date.distantPast
    private static let remainingCountRefreshInterval: TimeInterval = 5
    /// A durable dirty bit separates "the library changed" from "run a full
    /// eligibility sweep on every lifecycle/network callback". The first run
    /// after upgrading reconciles once; a proven-clean library then stays
    /// silent across launches until a real song/source mutation marks it dirty.
    private var queueNeedsRefresh = true
    private var queueMutationGeneration: Int
    private var reconciledQueueGeneration = -1
    private var persistedQueueState: QueueState?
    private var queueStatePersistenceTask: Task<Void, Never>?

    private var worker: Task<Void, Never>?
    private var executionMode: MetadataBackfillExecutionMode = .standard
    /// Source lifecycle notifications can arrive from the view, CloudKit and
    /// the global cleanup coordinator almost simultaneously. Coalesce them so
    /// removing several large sources scans the library once instead of once
    /// per notification/source on the main actor.
    private var pendingDiscardSourceIDs: Set<String> = []
    private var discardWorkTask: Task<Void, Never>?
    /// Exact session progress, kept non-observable so one completed network
    /// request doesn't invalidate every view that observes this service.
    private var processedTotal: Int = 0
    /// Debounced writer for the persisted metadata-state ID sets. Encoding and atomic
    /// file replacement run off the main actor.
    private var statePersistenceTask: Task<Void, Never>?
    /// Bumped on every `start()` / `stop()`. The worker captures its own
    /// generation and uses it to decide whether the cleanup at end-of-Task
    /// should clear shared state — without this, a cancelled-but-still-
    /// finishing worker can wipe `worker`/`isRunning` set by a new `start()`
    /// that ran between cancel and Task.value resumption.
    private var workerGeneration: Int = 0

    /// Worker 持有的 UIBackgroundTask ID, app 切到后台时给 backfill ~30 秒额外
    /// 收尾时间。worker 完成 / stop 时释放。expirationHandler 兜底 ── 系统提前
    /// 回收时主动 stop, 不留半挂状态。
    /// macOS 没有 UIBackgroundTask 机制 ── app 切后台就是后台进程, 不会被立即
    /// 挂起, 所以这块代码用 `#if os(iOS)` 整体守卫。
    #if os(iOS)
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    #endif

    init(
        library: MusicLibrary,
        sourceManager: SourceManager,
        backfillableSourceIDs: @escaping () -> Set<String> = { [] }
    ) {
        self.library = library
        self.sourceManager = sourceManager
        self.backfillableSourceIDs = backfillableSourceIDs
        let appSupport = FileManager.default.primuseDirectoryURL(for: .applicationSupportDirectory)
        let directory = appSupport.appendingPathComponent("Primuse", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.failedURL = directory.appendingPathComponent("backfill-failed.json")
        self.incompleteURL = directory.appendingPathComponent("backfill-incomplete.json")
        self.sourceIssueURL = directory.appendingPathComponent("backfill-source-issues.json")
        self.artworkGivenUpURL = directory.appendingPathComponent("backfill-artwork-givenup.json")
        self.titleCheckedURL = directory.appendingPathComponent("backfill-title-checked.json")
        self.albumArtistCheckedURL = directory.appendingPathComponent("backfill-album-artist-checked.json")
        self.artistCheckedURL = directory.appendingPathComponent("backfill-artist-checked.json")
        self.deferredRetryURL = directory.appendingPathComponent("backfill-deferred-retry.json")
        self.retryCountsURL = directory.appendingPathComponent("backfill-retry-counts.json")
        self.sourceRetryCountsURL = directory.appendingPathComponent("backfill-source-retry-counts.json")
        self.queueStateURL = directory.appendingPathComponent("backfill-queue-state.json")
        let defaults = UserDefaults.standard
        queueMutationGeneration = defaults.integer(
            forKey: Self.queueMutationGenerationDefaultsKey
        )
        if let data = try? Data(contentsOf: queueStateURL),
           let state = try? JSONDecoder().decode(QueueState.self, from: data) {
            persistedQueueState = state
            reconciledQueueGeneration = state.reconciledGeneration
            queueNeedsRefresh = state.needsRefresh
                || (defaults.object(forKey: Self.queueDirtyDefaultsKey) as? Bool ?? true)
                || state.reconciledGeneration != queueMutationGeneration
            cachedRemainingCount = state.remainingCount
            cachedFailedCount = state.failedCount
            cachedDeferredRetryCount = state.deferredRetryCount
            cachedStatusCount = state.statusCount
            remainingCountBySourceID = state.remainingCountBySourceID
            deferredRetryCountBySourceID = state.deferredRetryCountBySourceID
            statusCountBySourceID = state.statusCountBySourceID
        }
        loadFailed()
        loadIncomplete()
        loadSourceIssues()
        loadArtworkGivenUp()
        loadTitleChecked()
        loadAlbumArtistChecked()
        loadArtistChecked()
        loadDeferredRetries()
        loadRetryCounts()
        loadSourceRetryCounts()

        // The first deferred-retry implementation persisted every song in a
        // source snapshot after one connector failure. That inflated a three-
        // request network interruption into hundreds of visible retries. Clear
        // those ambiguous batch markers once; corrected builds persist only the
        // request that actually failed.
        let deferredBatchRepairKey = "primuse.backfillDeferredRetryReset.v2026_08_singleFailure"
        if !UserDefaults.standard.bool(forKey: deferredBatchRepairKey) {
            if !deferredRetrySongIDs.isEmpty {
                plog("📥 Backfill: clearing \(deferredRetrySongIDs.count) inflated deferred retry markers")
                deferredRetrySongIDs.removeAll()
                saveDeferredRetries()
            }
            UserDefaults.standard.set(true, forKey: deferredBatchRepairKey)
        }

        // One-time migration. Earlier builds had an overly-aggressive
        // partial-merge rule that marked any song as failed when head
        // 256KB didn't yield a duration — even if a tail-fetch would
        // have recovered it (M4A with udta in head, moov at tail are
        // the common victim). Field reports surfaced ~500 stuck songs
        // per library. Wipe the persisted set so those songs get a
        // fresh attempt under the corrected logic. Versioned key
        // prevents repeating on every launch.
        // v2026_06: 回填失败判定改为「区分瞬时/永久」后,清一次旧的 failedSongIDs,
        // 让此前被瞬时错误(源未就绪等)误钉成永久失败的歌按新逻辑重试。
        let migrationKey = "primuse.backfillFailedReset.v2026_06_transientRetry"
        if !UserDefaults.standard.bool(forKey: migrationKey), !failedSongIDs.isEmpty {
            plog("📥 Backfill: wiping \(failedSongIDs.count) failedSongIDs (one-time migration: transient/permanent split)")
            failedSongIDs.removeAll()
            saveFailed()
        }

        // v2026_06b: artwork-only failures used to land in failedSongIDs, which
        // dropped the song's (already parsed) duration at flush and stuck it
        // bare — playable songs that merely lacked an embedded cover ended up
        // unplayable with no cover. Now they go to artworkGivenUpIDs instead.
        // Wipe the old persisted failures once so anything stuck purely for a
        // missing cover gets a fresh pass and keeps its duration.
        let artworkDecoupleKey = "primuse.backfillFailedReset.v2026_06b_artworkDecouple"
        if !UserDefaults.standard.bool(forKey: artworkDecoupleKey) {
            if !failedSongIDs.isEmpty {
                plog("📥 Backfill: wiping \(failedSongIDs.count) failedSongIDs (one-time: artwork/fail decouple)")
                failedSongIDs.removeAll()
                saveFailed()
            }
            UserDefaults.standard.set(true, forKey: artworkDecoupleKey)
        }
        UserDefaults.standard.set(true, forKey: migrationKey)

        // Second one-time migration. The previous backfill stamped
        // many songs with SFB's truncated-head duration estimate
        // (typically 6–12 s for raw MP3s without XING/LAME, since
        // SFB only saw the first 256 KB). Sweep the library for
        // songs whose stored duration is < half what (fileSize ×
        // 8 / bitRate) predicts, reset their duration to 0, and
        // clear any matching failed mark so they re-enter the
        // queue. The corrected `correctedDuration` helper now
        // overwrites bogus parser values on the next pass.
        let durationFixKey = "primuse.backfillFailedReset.v2026_05_truncatedDuration"
        if !UserDefaults.standard.bool(forKey: durationFixKey) {
            var resetSongs: [Song] = []
            for song in library.songs {
                guard let bitRate = song.bitRate, bitRate > 0,
                      song.fileSize > Self.headBytes * 2,
                      song.duration > 0 else { continue }
                let bytesPerSec = Double(bitRate) * 125.0
                let estimatedFromFileSize = Double(song.fileSize) / bytesPerSec
                if song.duration < estimatedFromFileSize * 0.5 {
                    var copy = song
                    copy.duration = 0
                    resetSongs.append(copy)
                    failedSongIDs.remove(song.id)
                }
            }
            if !resetSongs.isEmpty {
                plog("📥 Backfill: resetting \(resetSongs.count) songs with truncated-head duration to re-trigger backfill")
                library.replaceSongs(resetSongs)
                saveFailed()
            }
            UserDefaults.standard.set(true, forKey: durationFixKey)
        }

        // Third one-time migration. Some older backfill results stored
        // `bitRate = 0` alongside the truncated-head MP3 duration, so
        // the previous sweep (which required a parsed bitrate) missed
        // exactly the field-reported shape: 3-5 MB MP3s saved as
        // 10-15 second tracks. Use the same conservative 192kbps
        // fallback as `correctedDuration` and reset only when the saved
        // duration is less than half the file-size estimate.
        let durationFallbackFixKey = "primuse.backfillFailedReset.v2026_05_truncatedDurationFallbackBitrate"
        if !UserDefaults.standard.bool(forKey: durationFallbackFixKey) {
            var resetSongs: [Song] = []
            for song in library.songs {
                guard song.fileFormat == .mp3,
                      (song.bitRate ?? 0) <= 0,
                      song.fileSize > Self.headBytes * 2,
                      song.duration > 0 else { continue }
                let bytesPerSec = Double(Self.defaultMP3Bitrate) * 125.0
                let estimatedFromFileSize = Double(song.fileSize) / bytesPerSec
                if song.duration < estimatedFromFileSize * 0.5 {
                    var copy = song
                    copy.duration = 0
                    resetSongs.append(copy)
                    failedSongIDs.remove(song.id)
                }
            }
            if !resetSongs.isEmpty {
                plog("📥 Backfill: resetting \(resetSongs.count) MP3 songs with truncated duration + missing bitrate")
                library.replaceSongs(resetSongs)
                saveFailed()
            }
            UserDefaults.standard.set(true, forKey: durationFallbackFixKey)
        }

        // Fourth one-time migration. Playback used to let SFB rewrite
        // cloud-stream duration from partial Range reads, so a healthy
        // 2-4 minute MP3 could regress back to ~8 seconds after the
        // previous migrations had already run. Reset every implausibly
        // short MP3 again, using parsed bitrate when available and the
        // conservative 192kbps fallback otherwise.
        let streamRewriteFixKey = "primuse.backfillFailedReset.v2026_05_streamDurationRewrite"
        if !UserDefaults.standard.bool(forKey: streamRewriteFixKey) {
            var resetSongs: [Song] = []
            for song in library.songs {
                guard song.fileFormat == .mp3,
                      song.fileSize > Self.headBytes * 2,
                      song.duration > 0 else { continue }
                let effectiveBitRate = (song.bitRate ?? 0) > 0 ? song.bitRate! : Self.defaultMP3Bitrate
                let estimatedFromFileSize = Double(song.fileSize) / (Double(effectiveBitRate) * 125.0)
                if estimatedFromFileSize > 30, song.duration < estimatedFromFileSize * 0.5 {
                    var copy = song
                    copy.duration = 0
                    resetSongs.append(copy)
                    failedSongIDs.remove(song.id)
                }
            }
            if !resetSongs.isEmpty {
                plog("📥 Backfill: resetting \(resetSongs.count) MP3 songs after partial stream duration rewrite")
                library.replaceSongs(resetSongs)
                saveFailed()
            }
            UserDefaults.standard.set(true, forKey: streamRewriteFixKey)
        }

        // Fifth one-time migration. FLAC backfill used to rely entirely on
        // AVFoundation reading a truncated 256KB temp file. Field reports from
        // OneDrive showed those rows being marked failed because duration stayed
        // at 0. The reader now parses FLAC STREAMINFO directly from the header,
        // so clear failed marks for duration-less FLAC rows and let them retry.
        let flacStreamInfoFixKey = "primuse.backfillFailedReset.v2026_06_flacStreamInfo"
        if !UserDefaults.standard.bool(forKey: flacStreamInfoFixKey) {
            let flacIDs = Set(library.songs.lazy.filter {
                $0.fileFormat == .flac && $0.duration <= 0
            }.map(\.id))
            let resetIDs = failedSongIDs.intersection(flacIDs)
            if !resetIDs.isEmpty {
                failedSongIDs.subtract(resetIDs)
                saveFailed()
                plog("📥 Backfill: clearing \(resetIDs.count) failed FLAC rows for STREAMINFO retry")
            }
            UserDefaults.standard.set(true, forKey: flacStreamInfoFixKey)
        }

        // Sixth one-time migration. Before partial ID3 results were persisted,
        // an MP3 whose title/artist parsed correctly but whose duration did not
        // was pinned in failedSongIDs forever. Give those rows one fresh pass:
        // the native TIT2/TPE1/TALB reader can now recover their text, and the
        // worker saves that text even if duration remains unavailable.
        let partialID3FixKey = "primuse.backfillFailedReset.v2026_07_partialID3Text"
        if !UserDefaults.standard.bool(forKey: partialID3FixKey) {
            let mp3IDs = Set(library.songs.lazy.filter {
                $0.fileFormat == .mp3
            }.map(\.id))
            let resetIDs = failedSongIDs.intersection(mp3IDs)
            if !resetIDs.isEmpty {
                failedSongIDs.subtract(resetIDs)
                sessionGivenUpIDs.subtract(resetIDs)
                titleCheckedIDs.subtract(resetIDs)
                for id in resetIDs { transientFailureCounts[id] = nil }
                saveFailed()
                saveTitleChecked()
                plog("📥 Backfill: clearing \(resetIDs.count) failed MP3 rows for partial ID3 text retry")
            }
            UserDefaults.standard.set(true, forKey: partialID3FixKey)
        }

        // Seventh one-time migration. AVFoundation reports the duration of a
        // truncated WAV Range temp file from the bytes physically present,
        // commonly 0.495 s for our 256 KB head. WAVEHeaderParser now uses the
        // complete byte count advertised by the RIFF `data` chunk. Reset only
        // the unmistakable old signature on backfillable remote sources so a
        // genuinely short local sound effect is never touched.
        let waveDurationFixKey = "primuse.backfillReset.v2026_07_waveRangeDuration"
        if !UserDefaults.standard.bool(forKey: waveDurationFixKey) {
            let sourceIDs = backfillableSourceIDs()
            var resetSongs: [Song] = []
            for song in library.songs {
                guard sourceIDs.contains(song.sourceID),
                      song.fileFormat == .wav,
                      song.fileSize > Self.headBytes * 2,
                      song.duration > 0,
                      song.duration < 1.5 else { continue }
                var copy = song
                copy.duration = 0
                resetSongs.append(copy)
                failedSongIDs.remove(song.id)
                sessionGivenUpIDs.remove(song.id)
                titleCheckedIDs.remove(song.id)
                transientFailureCounts[song.id] = nil
            }
            if !resetSongs.isEmpty {
                plog("📥 Backfill: resetting \(resetSongs.count) remote WAV rows with truncated Range duration")
                library.replaceSongs(resetSongs)
                saveFailed()
                saveTitleChecked()
            }
            UserDefaults.standard.set(true, forKey: waveDurationFixKey)
        }

        // Eighth one-time migration. WebDAV/OpenList proxies that ignored a
        // Range request used to feed an invalid whole response into metadata
        // backfill, and those duration-less rows could already be persisted as
        // failed. Metadata reads now consume a bounded head/tail window without
        // weakening playback Range validation, so give only still-bare songs
        // from backfillable sources one fresh attempt under the corrected path.
        let rangeIgnoringProxyFixKey = "primuse.backfillFailedReset.v2026_08_rangeIgnoringProxy"
        if !UserDefaults.standard.bool(forKey: rangeIgnoringProxyFixKey) {
            let sourceIDs = backfillableSourceIDs()
            let retryIDs = Set(library.songs.lazy.filter {
                sourceIDs.contains($0.sourceID) && $0.duration <= 0
            }.map(\.id))
            let resetIDs = failedSongIDs.intersection(retryIDs)
            if !resetIDs.isEmpty {
                failedSongIDs.subtract(resetIDs)
                sessionGivenUpIDs.subtract(resetIDs)
                titleCheckedIDs.subtract(resetIDs)
                for id in resetIDs { transientFailureCounts[id] = nil }
                saveFailed()
                saveTitleChecked()
                plog("📥 Backfill: clearing \(resetIDs.count) failed rows for Range-ignoring proxy retry")
            }
            UserDefaults.standard.set(true, forKey: rangeIgnoringProxyFixKey)
        }

        // Ninth one-time migration. A bounded MP3 header can expose a valid
        // MPEG bitrate without carrying a Xing/VBRI duration. Older backfill
        // code marked that row failed before its file-size/bitrate estimate
        // ran, so it stayed on "details unavailable" even though the stream
        // itself was valid. Retry only the rows that already have enough
        // technical evidence for the corrected path; corrupt/unknown payloads
        // remain failed instead of receiving a fabricated duration.
        let mp3BitrateDurationFixKey = "primuse.backfillFailedReset.v2026_08_mp3BitrateDuration"
        if !UserDefaults.standard.bool(forKey: mp3BitrateDurationFixKey) {
            let sourceIDs = backfillableSourceIDs()
            let retryIDs = Set(library.songs.lazy.filter {
                sourceIDs.contains($0.sourceID)
                    && $0.fileFormat == .mp3
                    && $0.duration <= 0
                    && $0.fileSize > Self.headBytes * 2
                    && ($0.bitRate ?? 0) > 0
            }.map(\.id))
            let resetIDs = failedSongIDs.intersection(retryIDs)
            if !resetIDs.isEmpty {
                failedSongIDs.subtract(resetIDs)
                sessionGivenUpIDs.subtract(resetIDs)
                titleCheckedIDs.subtract(resetIDs)
                for id in resetIDs { transientFailureCounts[id] = nil }
                saveFailed()
                saveTitleChecked()
                plog("📥 Backfill: clearing \(resetIDs.count) failed MP3 rows for bitrate duration recovery")
            }
            UserDefaults.standard.set(true, forKey: mp3BitrateDurationFixKey)
        }

        // Tenth one-time migration. Authenticated WebDAV sources can
        // redirect a media GET to an object-store/CDN endpoint. Older sessions
        // intentionally stopped at that cross-endpoint 302 and persisted a
        // metadata-backfill failure mark for an otherwise playable MP3. The transport now follows
        // read-only media redirects after removing source credentials, so give
        // still-bare remote MP3 rows one fresh pass.
        let webDAVMediaRedirectFixKey = "primuse.backfillFailedReset.v2026_08_webDAVMediaRedirect"
        if !UserDefaults.standard.bool(forKey: webDAVMediaRedirectFixKey) {
            let sourceIDs = backfillableSourceIDs()
            let retryIDs = Set(library.songs.lazy.filter {
                sourceIDs.contains($0.sourceID)
                    && $0.fileFormat == .mp3
                    && $0.duration <= 0
                    && $0.fileSize > 0
            }.map(\.id))
            let resetIDs = failedSongIDs.intersection(retryIDs)
            if !resetIDs.isEmpty {
                failedSongIDs.subtract(resetIDs)
                sessionGivenUpIDs.subtract(resetIDs)
                titleCheckedIDs.subtract(resetIDs)
                for id in resetIDs { transientFailureCounts[id] = nil }
                saveFailed()
                saveTitleChecked()
                plog("📥 Backfill: clearing \(resetIDs.count) failed remote MP3 rows for media-redirect retry")
            }
            UserDefaults.standard.set(true, forKey: webDAVMediaRedirectFixKey)
        }

        // The legacy failure set mixed stale successes, temporary source
        // outages, unknown durations and real parser failures. Split only the
        // cases supported by current row data: completed rows are cleared,
        // stream/complete-file-decoder rows become playable-incomplete, and
        // ambiguous rows receive one fresh bounded read for classification.
        // No Song field or remote object is changed by this migration.
        let detailsStateMigrationKey = "primuse.backfillState.v2026_08_detailsState"
        if !UserDefaults.standard.bool(forKey: detailsStateMigrationKey) {
            let songsByID = Dictionary(uniqueKeysWithValues: library.songs.map { ($0.id, $0) })
            var completedCount = 0
            var incompleteCount = 0
            var retryCount = 0
            for id in Array(failedSongIDs) {
                guard let song = songsByID[id] else {
                    failedSongIDs.remove(id)
                    continue
                }
                if song.duration > 0 {
                    failedSongIDs.remove(id)
                    completedCount += 1
                } else if song.isStreamDescriptor || song.fileFormat.requiresFFmpeg {
                    failedSongIDs.remove(id)
                    incompleteSongIDs.insert(id)
                    incompleteCount += 1
                } else {
                    failedSongIDs.remove(id)
                    titleCheckedIDs.remove(id)
                    retryCount += 1
                }
            }

            let suspiciousTitleIDs = Set(library.songs.lazy.filter {
                $0.userMetadataEditedAt == nil
                    && !ServerCatalogMetadataInspectionPolicy.hasUsableTitle($0.title)
            }.map(\.id))
            titleCheckedIDs.subtract(suspiciousTitleIDs)
            saveFailed()
            saveTitleChecked()
            UserDefaults.standard.set(true, forKey: detailsStateMigrationKey)
            plog(
                "📥 Backfill: migrated legacy details state "
                    + "(completed=\(completedCount) incomplete=\(incompleteCount) "
                    + "retry=\(retryCount) suspiciousTitles=\(suspiciousTitleIDs.count))"
            )
        }

        // Remote rows produced by the lossy-title path could be locked in both
        // titleCheckedIDs and incompleteSongIDs. Retry suspicious titles once
        // with the raw-ID3/filename policy, and retry incomplete remote MP3s
        // with the expanded MPEG-frame probe and bounded duration fallback.
        let cloudTitleAndDurationFixKey = "primuse.backfillState.v2026_08_cloudTitleAndDuration"
        if !UserDefaults.standard.bool(forKey: cloudTitleAndDurationFixKey) {
            let sourceIDs = backfillableSourceIDs()
            let retryIDs = Set(library.songs.lazy.filter { song in
                guard sourceIDs.contains(song.sourceID),
                      song.userMetadataEditedAt == nil else {
                    return false
                }
                let suspiciousTitle = MediaMetadataTextRepair.isSuspicious(song.title)
                    || TextEncodingRepair.requiresRawByteVerification(song.title)
                let incompleteMP3 = song.fileFormat == .mp3
                    && song.duration <= 0
                    && self.incompleteSongIDs.contains(song.id)
                return suspiciousTitle || incompleteMP3
            }.map(\.id))
            if !retryIDs.isEmpty {
                failedSongIDs.subtract(retryIDs)
                incompleteSongIDs.subtract(retryIDs)
                sessionGivenUpIDs.subtract(retryIDs)
                titleCheckedIDs.subtract(retryIDs)
                for id in retryIDs { transientFailureCounts[id] = nil }
                saveFailed()
                saveTitleChecked()
                plog("📥 Backfill: retrying \(retryIDs.count) remote rows for cloud title/duration repair")
            }
            UserDefaults.standard.set(true, forKey: cloudTitleAndDurationFixKey)
        }

        // Track artist used to have no independent completion marker. A FLAC
        // row could therefore be considered complete as soon as STREAMINFO
        // supplied duration, even when its Vorbis comments were beyond the
        // first 256 KB. Reconcile the queue once and reopen only failed remote
        // FLAC rows that still have no artist; successful absence is persisted
        // by artistCheckedIDs after the new bounded inspection.
        let remoteFLACArtistFixKey = "primuse.backfillState.v2026_08_remoteFLACArtist"
        if !UserDefaults.standard.bool(forKey: remoteFLACArtistFixKey) {
            let missingArtistIDs = Set(library.songs.lazy.filter { song in
                song.fileFormat == .flac
                    && (song.artistName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            }.map(\.id))
            let retryIDs = failedSongIDs.intersection(missingArtistIDs)
            if !retryIDs.isEmpty {
                failedSongIDs.subtract(retryIDs)
                sessionGivenUpIDs.subtract(retryIDs)
                artistCheckedIDs.subtract(retryIDs)
                for id in retryIDs { transientFailureCounts[id] = nil }
                saveFailed()
                saveInspectionState()
                plog("📥 Backfill: reopening \(retryIDs.count) remote FLAC rows for artist repair")
            }
            markQueueDirty()
            UserDefaults.standard.set(true, forKey: remoteFLACArtistFixKey)
        }

        // A re-scan that found a path with new bytes wipes the failed
        // mark so backfill re-attempts the song with the fresh file. The
        // song's metadata in the library is already reset to bare by
        // `MusicLibrary.addSongs`, so `start()` will pick it up next pass.
        NotificationCenter.default.addObserver(
            forName: .primuseSongContentChanged,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            let songs = (note.userInfo?["songs"] as? [Song]) ?? []
            guard !songs.isEmpty else { return }
            MainActor.assumeIsolated {
                let ids = Set(songs.map(\.id))
                self.failedSongIDs.subtract(ids)
                self.incompleteSongIDs.subtract(ids)
                self.sourceIssueSongIDs.subtract(ids)
                self.sessionGivenUpIDs.subtract(ids)
                self.sessionNetworkParkedIDs.subtract(ids)
                self.sessionStallParkedIDs.subtract(ids)
                self.deferredRetrySongIDs.subtract(ids)
                self.titleCheckedIDs.subtract(ids)
                self.albumArtistCheckedIDs.subtract(ids)
                self.artistCheckedIDs.subtract(ids)
                for id in ids { self.transientFailureCounts[id] = nil }
                for sourceID in Set(songs.map(\.sourceID)) {
                    self.sourceTransientFailureCounts[sourceID] = nil
                }
                self.saveFailed()
                self.saveDeferredRetries()
                self.saveInspectionState()
                self.saveRetryCounts()
                self.refreshQueue(startImmediately: Self.canRunAutomaticMaintenance)
            }
        }

        NotificationCenter.default.addObserver(
            forName: .primuseSourceDidSoftDelete,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self, let id = note.userInfo?["id"] as? String else { return }
            MainActor.assumeIsolated {
                self.discardWork(forSourceID: id)
            }
        }

        NotificationCenter.default.addObserver(
            forName: .primuseSourceDidDelete,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self, let id = note.userInfo?["id"] as? String else { return }
            MainActor.assumeIsolated {
                self.discardWork(forSourceID: id)
            }
        }
    }

    /// Changes future dispatch cadence without discarding queue state. Moving
    /// into real background playback also releases the short UIKit assertion
    /// so its expiration cannot stop an audio-backed execution window.
    func setExecutionMode(_ mode: MetadataBackfillExecutionMode) {
        guard executionMode != mode else { return }
        executionMode = mode
        if mode == .backgroundDuringPlayback {
            // Real background audio already keeps the process eligible to run.
            // Holding a short UIApplication assertion here would make its
            // expiration handler stop an otherwise healthy slow queue at the
            // ~30 second boundary.
            endBackgroundTaskIfHeld()
        } else if isRunning {
            beginBackgroundTaskIfNeeded()
        }
        plog("📥 Backfill: execution mode -> \(String(describing: mode))")
    }

    /// Start (or resume) backfill. Idempotent — if a worker is already
    /// running this is a no-op. A durable clean state returns before touching
    /// the library array. Wi-Fi-only gating remains enforced before dispatch.
    func start() {
        guard worker == nil else {
            // Worker still in flight — common during initial scan when
            // multiple onChange events fire. Logging was added because
            // a "spinner never stops" report initially looked like
            // start() wasn't being called at all.
            plog("📥 Backfill: skip (worker already running, gen=\(workerGeneration))")
            return
        }
        guard hasPendingWork else { return }
        refreshRemainingCounts(force: true)
        guard cachedRemainingCount > 0 else { return }

        // Cellular gate. Backfill on a 2200-song cloud library is ~550MB —
        // enough to be a problem on metered connections. Instead of silently
        // deferring, surface a prompt (pausedForCellular) when there's actually
        // work to do, so the user can opt into 5G/4G if they need it.
        if shouldBlockForCellular() {
            updateWaitingForWiFiState(presentPrompt: true)
            plog("📥 Backfill: deferred (cellular + Wi-Fi-only); pendingWork=\(hasPendingWork) prompt=\(pausedForCellular)")
            return
        }
        isWaitingForWiFi = false
        setCellularPromptPresented(false)

        let limits = MetadataBackfillExecutionPolicy.limits(for: executionMode)
        let needsBackfill = pickNextBatch(limit: limits.snapshotLimit)
        guard !needsBackfill.isEmpty else {
            // Either every song has metadata OR every bare song is in
            // failedSongIDs. Surface both numbers so a "spinner stuck"
            // report can be triaged from the log without app-side
            // instrumentation.
            let sourceIDs = backfillableSourceIDs()
            let bareTotal = library.songs.lazy.filter {
                sourceIDs.contains($0.sourceID) && Self.isBareSong($0)
            }.count
            plog("📥 Backfill: skip (no eligible bare songs — total=\(library.songs.count) bare=\(bareTotal) failed=\(failedSongIDs.count))")
            return
        }
        pendingCount = needsBackfill.count
        processedTotal = 0
        processedCount = 0
        isRunning = true
        workerGeneration += 1
        let generation = workerGeneration
        beginBackgroundTaskIfNeeded()
        // Diagnostic: prove that we only pick still-bare songs. If you see
        // this number stay >0 forever you can compare against
        // `library.songs.count` to confirm no infinite reprocessing.
        plog("📥 Backfill: gen=\(generation) mode=\(String(describing: executionMode)) bareInLib=\(remainingCount) batchHead=\(needsBackfill.count)")
        worker = Task { [weak self] in
            await self?.runWorker()
            await MainActor.run { [weak self] in
                guard let self, self.workerGeneration == generation else { return }
                let processed = self.processedTotal
                self.processedCount = processed
                self.worker = nil
                self.isRunning = false
                self.activeSourceIDs.removeAll()
                self.pendingCount = 0
                self.refreshRemainingCounts(force: true)
                self.updateWaitingForWiFiState(presentPrompt: true)
                self.endBackgroundTaskIfHeld()
                if self.executionMode == .foregroundAfterSourceScan {
                    self.setExecutionMode(.standard)
                }
                // 完成通知 ── 处理 >= 5 首才发, 避免每次 worker 短跑都打扰用户。
                // hasPendingWork == false 表示当前没遗留 ── 队列全清才算"完成"。
                // postIfEnabled 内部会检查用户在设置页是否开了开关 + 系统是否已授权,
                // 不满足条件直接 noop。
                if processed >= 5 && !self.hasPendingWork {
                    let processedCount = processed
                    Task {
                        await UserNotificationService.shared.postLongTaskCompletion(
                            category: .rescrapeLibraryDone,
                            title: String(localized: "backfill_done_title"),
                            body: String(format: String(localized: "backfill_done_body"), processedCount)
                        )
                    }
                }
            }
        }
    }

    private func beginBackgroundTaskIfNeeded() {
        #if os(iOS)
        // A foreground backfill may take far longer than the roughly
        // 30-second UIApplication background window. Start an assertion only
        // after the scene is actually inactive/background; PrimuseApp stops
        // the foreground worker during the transition and restarts it once
        // the background scene has settled.
        guard executionMode != .backgroundDuringPlayback else { return }
        guard UIApplication.shared.applicationState != .active else { return }
        guard backgroundTaskID == .invalid else { return }
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "primuse.backfill") { [weak self] in
            // System wants the time back ── stop worker gracefully, release token.
            // 之前没这个 expirationHandler, app 切到后台时 backfill 立刻被挂起,
            // 没机会 flush in-flight batch。现在能多 30 秒优雅收尾。
            Task { @MainActor [weak self] in
                self?.stop()
                self?.endBackgroundTaskIfHeld()
            }
        }
        plog("📥 Backfill: beginBackgroundTask id=\(backgroundTaskID.rawValue)")
        #endif
    }

    private func endBackgroundTaskIfHeld() {
        #if os(iOS)
        guard backgroundTaskID != .invalid else { return }
        let id = backgroundTaskID
        backgroundTaskID = .invalid
        UIApplication.shared.endBackgroundTask(id)
        plog("📥 Backfill: endBackgroundTask id=\(id.rawValue)")
        #endif
    }

    /// Stop the worker after the in-flight song finishes. Safe to call on
    /// background-task expiration; nothing is left in a half-state because
    /// `replaceSong` is atomic. Bumping the generation here is what tells
    /// the in-flight worker's MainActor cleanup block to skip — it's no
    /// longer the "current" worker, so it must not touch shared state.
    func stop() {
        workerGeneration += 1
        worker?.cancel()
        worker = nil
        isRunning = false
        activeSourceIDs.removeAll()
        pendingCount = 0
        updateWaitingForWiFiState(presentPrompt: false)
        endBackgroundTaskIfHeld()
        if executionMode == .foregroundAfterSourceScan {
            setExecutionMode(.standard)
        }
    }

    /// Re-evaluate active work after a source was enabled or disabled. Only
    /// that source's transient circuit-breaker state is reset; changing one
    /// connector must not silently grant fresh retries to every other source.
    /// Permanently unparseable rows remain excluded by `failedSongIDs`.
    func sourceAvailabilityChanged(forSourceID sourceID: String) {
        stop()
        let songIDs = Set(library.songs.lazy.filter {
            $0.sourceID == sourceID
        }.map(\.id))
        sourceIssueSongIDs.subtract(songIDs)
        sessionGivenUpIDs.subtract(songIDs)
        sessionNetworkParkedIDs.subtract(songIDs)
        sessionStallParkedIDs.subtract(songIDs)
        for id in songIDs { transientFailureCounts[id] = nil }
        sourceTransientFailureCounts[sourceID] = nil
        saveFailed()
        saveRetryCounts()
        refreshQueue(startImmediately: Self.canRunAutomaticMaintenance)
    }

    /// A completed source scan proves that catalogue access has recovered and
    /// may also have committed brand-new bare rows. If an older outage exhausted
    /// the source-wide backfill circuit breaker, grant the unresolved rows one
    /// fresh bounded retry budget. Every successful scan with eligible rows
    /// refreshes the queue; an active iOS scene runs only one gentle pass.
    func sourceScanSucceeded(forSourceID sourceID: String) {
        let retryableSongIDs = Set(library.songs.lazy.filter { [self] song in
            song.sourceID == sourceID
                && !failedSongIDs.contains(song.id)
                && !sourceIssueSongIDs.contains(song.id)
                && !sessionStallParkedIDs.contains(song.id)
                && needsBackfill(song)
        }.map(\.id))
        guard !retryableSongIDs.isEmpty else { return }

        let sourceAttemptCount = sourceTransientFailureCounts[sourceID] ?? 0
        if MetadataBackfillSourceRecoveryPolicy.shouldRenewRetryBudget(
            sourceAttemptCount: sourceAttemptCount,
            unresolvedSongCount: retryableSongIDs.count
        ) {
            sessionGivenUpIDs.subtract(retryableSongIDs)
            sessionNetworkParkedIDs.subtract(retryableSongIDs)
            for songID in retryableSongIDs {
                transientFailureCounts[songID] = nil
            }
            sourceTransientFailureCounts[sourceID] = nil
            saveRetryCounts()
            plog(
                "📥 Backfill: successful source scan renewed exhausted retry budget "
                    + "source=\(sourceID) unresolved=\(retryableSongIDs.count)"
            )
        }

        #if os(iOS)
        if UIApplication.shared.applicationState == .active {
            setExecutionMode(.foregroundAfterSourceScan)
            refreshQueue(startImmediately: true)
        } else {
            refreshQueue(startImmediately: Self.canRunAutomaticMaintenance)
        }
        #else
        refreshQueue()
        #endif
    }

    /// Drop queued work for a source that was removed. The
    /// worker processes fixed snapshots, so without stopping it a deleted
    /// 10K-song source can keep burning through stale rows until relaunch.
    func discardWork(forSourceID sourceID: String) {
        discardWork(forSourceIDs: [sourceID])
    }

    func discardWork(forSourceIDs sourceIDs: Set<String>) {
        guard !sourceIDs.isEmpty else { return }
        pendingDiscardSourceIDs.formUnion(sourceIDs)
        // Network work must stop immediately; only the potentially expensive
        // library/state sweep is debounced.
        stop()

        discardWorkTask?.cancel()
        discardWorkTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(300))
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.flushPendingDiscardWork()
        }
    }

    /// Used by the source-cleanup coordinator immediately before it removes
    /// the songs from MusicLibrary. Waiting for the debounce after that point
    /// would lose the IDs needed to clear the persisted backfill state.
    func discardWorkNow(forSourceIDs sourceIDs: Set<String>) {
        guard !sourceIDs.isEmpty else { return }
        pendingDiscardSourceIDs.formUnion(sourceIDs)
        stop()
        discardWorkTask?.cancel()
        discardWorkTask = nil
        flushPendingDiscardWork()
    }

    private func flushPendingDiscardWork() {
        let sourceIDs = pendingDiscardSourceIDs
        pendingDiscardSourceIDs.removeAll(keepingCapacity: true)
        discardWorkTask = nil
        guard !sourceIDs.isEmpty else { return }

        let songIDs = Set(library.songs.lazy.filter {
            sourceIDs.contains($0.sourceID)
        }.map(\.id))
        guard !songIDs.isEmpty else { return }
        failedSongIDs.subtract(songIDs)
        incompleteSongIDs.subtract(songIDs)
        sourceIssueSongIDs.subtract(songIDs)
        sessionGivenUpIDs.subtract(songIDs)
        sessionNetworkParkedIDs.subtract(songIDs)
        sessionStallParkedIDs.subtract(songIDs)
        deferredRetrySongIDs.subtract(songIDs)
        titleCheckedIDs.subtract(songIDs)
        albumArtistCheckedIDs.subtract(songIDs)
        artistCheckedIDs.subtract(songIDs)
        for id in songIDs { transientFailureCounts[id] = nil }
        for sourceID in sourceIDs { sourceTransientFailureCounts[sourceID] = nil }
        saveFailed()
        saveDeferredRetries()
        saveInspectionState()
        saveRetryCounts()
        markQueueDirty()
    }

    /// Re-evaluate the queue every time the library changes (e.g. a fresh
    /// scan added new bare songs). Call after scan completion or song add.
    func refreshQueue(startImmediately: Bool = true) {
        markQueueDirty()
        if startImmediately, worker == nil { start() }
    }

    /// A genuinely new usable network path grants one more automatic attempt to
    /// work parked by transport failures, without resetting its persisted retry
    /// budget. Stalled state-application snapshots remain parked because a route
    /// change cannot make an in-memory library write start sticking.
    func networkPathChanged(startImmediately: Bool = true) {
        guard hasPendingWork || !sessionNetworkParkedIDs.isEmpty else { return }
        guard NetworkMonitor.shared.isReachable, !shouldBlockForCellular() else {
            updateWaitingForWiFiState(presentPrompt: true)
            return
        }
        resumeNetworkParkedWork()
        if startImmediately, worker == nil { start() }
    }

    private func resumeNetworkParkedWork() {
        guard !sessionNetworkParkedIDs.isEmpty else { return }
        let retryableIDs = Set(sessionNetworkParkedIDs.filter { songID in
            guard let song = library.song(id: songID) else { return false }
            return !Self.automaticRetriesExhausted(
                songID: songID,
                sourceID: song.sourceID,
                retryCounts: transientFailureCounts,
                sourceRetryCounts: sourceTransientFailureCounts
            )
        })
        guard !retryableIDs.isEmpty else { return }
        sessionNetworkParkedIDs.subtract(retryableIDs)
        sessionGivenUpIDs.subtract(retryableIDs)
        refreshRemainingCounts(force: true)
        plog("📥 Backfill: network path changed; resumed \(retryableIDs.count) deferred inspections")
    }

    /// Called by scanners for IDs whose title source was already inspected in
    /// this scan. A usable server-catalog title does not prove that the file's
    /// album-artist tag was inspected, so that independent leg stays open.
    func acknowledgeScannerMetadataInspection(songIDs: Set<String>) {
        guard !songIDs.isEmpty else { return }
        let previousTitleCount = titleCheckedIDs.count
        titleCheckedIDs.formUnion(songIDs)
        guard titleCheckedIDs.count != previousTitleCount else { return }
        saveInspectionState()
        refreshRemainingCounts(force: true)
    }

    /// Block until the worker finishes draining the current queue. Used by
    /// the BGProcessingTask handler so iOS doesn't yank us mid-work.
    func waitUntilIdle() async {
        while worker != nil {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }
    }

    /// Duration is the load-bearing signal for legacy rows, but the worker also
    /// owns one-time title, embedded-artwork, and album-artist inspections.
    /// Each leg has its own completion marker so a legitimately absent optional
    /// tag never makes the song eligible forever.
    static func isBareSong(_ song: Song) -> Bool {
        song.duration <= 0
    }

    /// True if there are bare songs in the library that backfill could
    /// process. Reflects queue state, not just whether a worker is
    /// currently running — a cellular-paused service shows
    /// `isRunning == false` but still has pending work that should keep
    /// BGProcessingTask scheduled.
    var hasPendingWork: Bool {
        queueNeedsRefresh
            || reconciledQueueGeneration != queueMutationGeneration
            || cachedRemainingCount > 0
    }

    var activityState: MetadataBackfillActivityState {
        .resolve(
            hasPendingWork: hasPendingWork,
            isRunning: isRunning,
            isWaitingForWiFi: isWaitingForWiFi,
            hasDeferredRetryWork: hasDeferredRetryWork
        )
    }

    func activityState(forSource sourceID: String) -> MetadataBackfillActivityState {
        .resolve(
            hasPendingWork: remainingCount(forSource: sourceID) > 0,
            isRunning: isRunning && activeSourceIDs.contains(sourceID),
            isWaitingForWiFi: isWaitingForWiFi,
            hasDeferredRetryWork: deferredRetryCount(forSource: sourceID) > 0
        )
    }

    /// Number of songs currently waiting for backfill. Used by the UI to
    /// show "loading details · N remaining" — the older `pendingCount`
    /// was a snapshot at start time so it could disagree with reality
    /// after Phase A added more bare songs mid-backfill.
    var remainingCount: Int {
        cachedRemainingCount
    }

    /// Persisted transient retries overlap with the active queue after a
    /// relaunch. `statusCount` avoids double-counting that overlap while still
    /// keeping a parked retry visible after the current worker gives up.
    var statusCount: Int {
        cachedStatusCount
    }

    var hasDeferredRetryWork: Bool {
        cachedDeferredRetryCount > 0
    }

    func detailsState(for song: Song, isLocalSource: Bool) -> SongDetailsState {
        let waitingForSource = sourceIssueSongIDs.contains(song.id)
            || sessionGivenUpIDs.contains(song.id)
            || Self.automaticRetriesExhausted(
                songID: song.id,
                sourceID: song.sourceID,
                retryCounts: transientFailureCounts,
                sourceRetryCounts: sourceTransientFailureCounts
            )
            || library.disabledSourceIDs.contains(song.sourceID)
            || (isWaitingForWiFi && needsBackfill(song))
        let confirmedFailure = failedSongIDs.contains(song.id)
        let incomplete = incompleteSongIDs.contains(song.id)
            || (isLocalSource && song.duration <= 0 && song.isPlayable)
        let reading = !waitingForSource
            && !confirmedFailure
            && needsBackfill(song)

        return .resolve(
            duration: song.duration,
            isStandaloneMusicVideo: song.isStandaloneMusicVideo,
            isPlayable: song.isPlayable,
            isReading: reading,
            isWaitingForSource: waitingForSource,
            isIncomplete: incomplete,
            hasConfirmedFailure: confirmedFailure
        )
    }

    /// Per-source variant — used by the source card so its "remaining"
    /// number matches the global storage page rather than counting
    /// songs that backfill has given up on.
    func remainingCount(forSource sourceID: String?) -> Int {
        guard let sourceID else { return cachedRemainingCount }
        return remainingCountBySourceID[sourceID] ?? 0
    }

    func deferredRetryCount(forSource sourceID: String?) -> Int {
        guard let sourceID else { return cachedDeferredRetryCount }
        return deferredRetryCountBySourceID[sourceID] ?? 0
    }

    func statusCount(forSource sourceID: String?) -> Int {
        guard let sourceID else { return cachedStatusCount }
        return statusCountBySourceID[sourceID] ?? 0
    }

    func isDeferredRetry(songID: String) -> Bool {
        deferredRetrySongIDs.contains(songID)
    }

    private func refreshRemainingCounts(force: Bool = false) {
        let now = Date()
        guard force
                || now.timeIntervalSince(lastRemainingCountRefreshAt)
                    >= Self.remainingCountRefreshInterval else { return }
        lastRemainingCountRefreshAt = now
        let sourceIDs = backfillableSourceIDs()
        let songs = library.songs
        let failedIDs = failedSongIDs
        let incompleteIDs = incompleteSongIDs
        let sourceIssueIDs = sourceIssueSongIDs
        let sessionGivenUpSnapshot = sessionGivenUpIDs
        let retryCountSnapshot = transientFailureCounts
        let sourceRetryCountSnapshot = sourceTransientFailureCounts
        let artworkGivenUpSnapshot = artworkGivenUpIDs
        let titleCheckedSnapshot = titleCheckedIDs
        let albumArtistCheckedSnapshot = albumArtistCheckedIDs
        let artistCheckedSnapshot = artistCheckedIDs
        let deferredRetrySnapshot = deferredRetrySongIDs
        var bySource: [String: Int] = [:]
        var deferredBySource: [String: Int] = [:]
        var statusBySource: [String: Int] = [:]
        bySource.reserveCapacity(sourceIDs.count)
        deferredBySource.reserveCapacity(sourceIDs.count)
        statusBySource.reserveCapacity(sourceIDs.count)
        var total = 0
        var deferredTotal = 0
        var statusTotal = 0
        var failedTotal = 0
        for song in songs {
            guard sourceIDs.contains(song.sourceID) else { continue }

            let stillNeedsDetails = Self.needsBackfill(
                song,
                artworkGivenUpIDs: artworkGivenUpSnapshot,
                titleCheckedIDs: titleCheckedSnapshot,
                incompleteSongIDs: incompleteIDs,
                albumArtistCheckedIDs: albumArtistCheckedSnapshot,
                artistCheckedIDs: artistCheckedSnapshot
            )
            let hasTerminalOrSourceFailure = failedIDs.contains(song.id)
                || sourceIssueIDs.contains(song.id)
            let automaticRetriesExhausted = Self.automaticRetriesExhausted(
                songID: song.id,
                sourceID: song.sourceID,
                retryCounts: retryCountSnapshot,
                sourceRetryCounts: sourceRetryCountSnapshot
            )
            let isDeferredRetry = deferredRetrySnapshot.contains(song.id)
                && !hasTerminalOrSourceFailure
                && stillNeedsDetails
            if isDeferredRetry {
                deferredBySource[song.sourceID, default: 0] += 1
                deferredTotal += 1
            }

            let hasFailed = hasTerminalOrSourceFailure
                || sessionGivenUpSnapshot.contains(song.id)
                || automaticRetriesExhausted
            // `statusCount` is the truthful unresolved-inspection total shown
            // on source cards. A source circuit breaker can park hundreds of
            // untouched rows after one real request fails; keep all those rows
            // in the total while `deferredRetryCount` reports only the request
            // IDs that actually failed.
            if stillNeedsDetails && !hasTerminalOrSourceFailure {
                statusBySource[song.sourceID, default: 0] += 1
                statusTotal += 1
            }
            if hasFailed {
                if stillNeedsDetails { failedTotal += 1 }
                continue
            }
            guard stillNeedsDetails else { continue }
            bySource[song.sourceID, default: 0] += 1
            total += 1
        }
        if remainingCountBySourceID != bySource {
            remainingCountBySourceID = bySource
        }
        if cachedRemainingCount != total {
            cachedRemainingCount = total
        }
        if deferredRetryCountBySourceID != deferredBySource {
            deferredRetryCountBySourceID = deferredBySource
        }
        if cachedDeferredRetryCount != deferredTotal {
            cachedDeferredRetryCount = deferredTotal
        }
        if statusCountBySourceID != statusBySource {
            statusCountBySourceID = statusBySource
        }
        if cachedStatusCount != statusTotal {
            cachedStatusCount = statusTotal
        }
        if cachedFailedCount != failedTotal {
            cachedFailedCount = failedTotal
        }
        reconciledQueueGeneration = queueMutationGeneration
        queueNeedsRefresh = false
        persistQueueStateIfNeeded(needsRefresh: false)
        if total == 0 {
            isWaitingForWiFi = false
            setCellularPromptPresented(false)
        }
    }

    private func markQueueDirty() {
        queueMutationGeneration = queueMutationGeneration == .max
            ? 1
            : queueMutationGeneration + 1
        queueNeedsRefresh = true
        let defaults = UserDefaults.standard
        defaults.set(
            queueMutationGeneration,
            forKey: Self.queueMutationGenerationDefaultsKey
        )
        defaults.set(true, forKey: Self.queueDirtyDefaultsKey)
        persistQueueStateIfNeeded(needsRefresh: true)
    }

    private func persistQueueStateIfNeeded(needsRefresh: Bool) {
        let state = QueueState(
            needsRefresh: needsRefresh,
            reconciledGeneration: reconciledQueueGeneration,
            remainingCount: cachedRemainingCount,
            failedCount: cachedFailedCount,
            deferredRetryCount: cachedDeferredRetryCount,
            statusCount: cachedStatusCount,
            remainingCountBySourceID: remainingCountBySourceID,
            deferredRetryCountBySourceID: deferredRetryCountBySourceID,
            statusCountBySourceID: statusCountBySourceID
        )
        guard persistedQueueState != state else { return }
        persistedQueueState = state
        let url = queueStateURL
        let previous = queueStatePersistenceTask
        queueStatePersistenceTask = Task.detached(priority: .utility) {
            _ = await previous?.value
            guard let data = try? JSONEncoder().encode(state) else { return }
            do {
                try data.write(to: url, options: .atomic)
                UserDefaults.standard.set(
                    state.needsRefresh,
                    forKey: Self.queueDirtyDefaultsKey
                )
            } catch {
                UserDefaults.standard.set(true, forKey: Self.queueDirtyDefaultsKey)
            }
        }
    }

    private static var canRunAutomaticMaintenance: Bool {
        #if os(iOS)
        UIApplication.shared.applicationState == .background
        #else
        true
        #endif
    }

    /// Number of songs whose remaining inspection work is currently blocked by
    /// a terminal error, an exhausted retry budget, or a session park.
    var failedCount: Int {
        cachedFailedCount
    }

    /// Explicit user retry resets both per-song and source-wide automatic retry
    /// budgets. Only rows that still have inspection work and are actually
    /// blocked are reopened.
    func retryFailed() {
        let retrySongs = library.songs.filter { song in
            guard needsBackfill(song) else { return false }
            return failedSongIDs.contains(song.id)
                || sourceIssueSongIDs.contains(song.id)
                || sessionGivenUpIDs.contains(song.id)
                || Self.automaticRetriesExhausted(
                    songID: song.id,
                    sourceID: song.sourceID,
                    retryCounts: transientFailureCounts,
                    sourceRetryCounts: sourceTransientFailureCounts
                )
        }
        let retryIDs = Set(retrySongs.map(\.id))
        guard !retryIDs.isEmpty else { return }
        let sourceIDs = Set(retrySongs.map(\.sourceID))
        failedSongIDs.subtract(retryIDs)
        incompleteSongIDs.subtract(retryIDs)
        sourceIssueSongIDs.subtract(retryIDs)
        sessionGivenUpIDs.subtract(retryIDs)
        sessionNetworkParkedIDs.subtract(retryIDs)
        sessionStallParkedIDs.subtract(retryIDs)
        deferredRetrySongIDs.formUnion(retryIDs)
        artworkGivenUpIDs.subtract(retryIDs)
        titleCheckedIDs.subtract(retryIDs)
        albumArtistCheckedIDs.subtract(retryIDs)
        artistCheckedIDs.subtract(retryIDs)
        for id in retryIDs { transientFailureCounts[id] = nil }
        for sourceID in sourceIDs { sourceTransientFailureCounts[sourceID] = nil }
        saveFailed()
        saveDeferredRetries()
        saveInspectionState()
        saveRetryCounts()
        plog("📥 Backfill: retryFailed reopened \(retryIDs.count) blocked inspections")
        refreshRemainingCounts(force: true)
        start()
    }

    func retry(songID: String) {
        guard library.song(id: songID) != nil else { return }
        failedSongIDs.remove(songID)
        incompleteSongIDs.remove(songID)
        sourceIssueSongIDs.remove(songID)
        sessionGivenUpIDs.remove(songID)
        sessionNetworkParkedIDs.remove(songID)
        sessionStallParkedIDs.remove(songID)
        deferredRetrySongIDs.insert(songID)
        artworkGivenUpIDs.remove(songID)
        titleCheckedIDs.remove(songID)
        albumArtistCheckedIDs.remove(songID)
        artistCheckedIDs.remove(songID)
        transientFailureCounts[songID] = nil
        if let sourceID = library.song(id: songID)?.sourceID {
            sourceTransientFailureCounts[sourceID] = nil
        }
        saveFailed()
        saveDeferredRetries()
        saveInspectionState()
        saveRetryCounts()
        refreshRemainingCounts(force: true)
        start()
    }

    // MARK: - Worker

    /// Large cloud libraries need far fewer whole-library cache/index rebuilds.
    /// Network requests still complete continuously; only the observable
    /// library publication is coalesced.
    private static let flushBatchSize = 250
    /// Flush cadence and worker count come from
    /// MetadataBackfillExecutionPolicy. Standard work retains the historical
    /// three-worker throughput; iOS background modes are serial and throttled.
    /// Hard cap for a single song's metadata backfill. Some SMB/NAS stacks can
    /// leave a READ or AVFoundation metadata load suspended indefinitely for a
    /// damaged or locked file. Let that file go and keep the queue moving.
    private static let perSongTimeout: TimeInterval = 45
    private func runWorker() async {
        // Outer loop: take a snapshot of bare songs, process the snapshot
        // sequentially, flush in batches. We deliberately do NOT call
        // `pickNextBatch` per-song — until we flush the batch the
        // already-processed songs still look "bare" in the library and
        // would be picked again, causing duplicate Range fetches and a
        // weird-looking processedCount that grows past pendingCount.
        var lastSnapshotIDs: Set<String> = []
        var completedSnapshotPasses = 0
        while !Task.isCancelled {
            let blockedByCellular = await MainActor.run { [self] in shouldBlockForCellular() }
            if blockedByCellular {
                plog("📥 Backfill: pausing (cellular detected mid-flight)")
                break
            }

            let limits = await MainActor.run { [self] in
                MetadataBackfillExecutionPolicy.limits(for: executionMode)
            }
            if let snapshotPassLimit = limits.snapshotPassLimit,
               completedSnapshotPasses >= snapshotPassLimit {
                break
            }

            let snapshot = await MainActor.run { [self] in
                return pickNextBatch(limit: limits.snapshotLimit)
            }
            if snapshot.isEmpty { break }

            // Oscillation guard: if pickNextBatch keeps returning the
            // exact same set of song IDs after we already processed
            // them, our writes aren't sticking — replaceSongs failed,
            // backfill returned duration=0 despite reporting "done", or
            // some other code path is silently overwriting the merged
            // result back to bare. Bail to avoid burning quota in an
            // infinite loop, and surface the diagnostic so we can
            // pinpoint where the round-trip drops the duration.
            let snapIDs = Set(snapshot.map(\.id))
            if MetadataBackfillStallPolicy.shouldParkRepeatedSnapshot(
                previousIDs: lastSnapshotIDs,
                currentIDs: snapIDs
            ) {
                sessionGivenUpIDs.formUnion(snapIDs)
                sessionStallParkedIDs.formUnion(snapIDs)
                let deferredIDs = MetadataBackfillDeferredRetryPolicy.idsToPersist(
                    failedSongID: nil,
                    snapshotSongIDs: snapIDs,
                    cause: .repeatedSnapshot
                )
                deferredRetrySongIDs.formUnion(deferredIDs)
                if !deferredIDs.isEmpty { saveDeferredRetries() }
                refreshRemainingCounts(force: true)
                plog("⚠️ Backfill: pickNextBatch returned the same \(snapIDs.count) IDs after a full round — parked for this session")
                break
            }
            lastSnapshotIDs = snapIDs

            activeSourceIDs = Set(snapshot.map(\.sourceID))
            await processSnapshot(snapshot)
            completedSnapshotPasses += 1
        }
    }

    /// Process a fixed list of songs with the active bounded concurrency,
    /// flushing the library
    /// every `flushBatchSize` successes (or every `flushInterval` seconds).
    /// Each song in the snapshot is touched exactly once.
    private func processSnapshot(_ snapshot: [Song]) async {
        var pendingFlush: [Song] = []
        var pendingArtistInspectionIDs: Set<String> = []
        var lastFlushAt = Date()
        plog("📥 processSnapshot: starting with \(snapshot.count) songs")

        // 预热阶段: 按 source 分组, 给每个 source 调一次 batch prefetchMetadata
        // (百度网盘会一次拿 100 个 dlink, 其他 connector 默认 noop)。后续每首
        // 的 fetchRange 走 dlink cache 命中, 省掉 1w 次 filemetas API 配额。
        let songsBySource: [String: [Song]] = Dictionary(grouping: snapshot) { $0.sourceID }
        for (_, sourceSongs) in songsBySource {
            guard !Task.isCancelled else { return }
            guard let representative = sourceSongs.first else { continue }
            guard isStillEligible(representative) else { continue }
            if let connector = try? await sourceManager.connectorForSong(representative) {
                let paths = sourceSongs.map(\.filePath)
                await connector.prefetchMetadata(paths: paths)
            }
        }

        // 并发 worker 拉取 ── TaskGroup pull-pattern, 启动 N 个 task 跑 processOne,
        // 谁完成立刻拿下一首。比 chunk 切片均匀, 慢源 / 快源混合时不会被慢
        // 元素拖整批进度。pendingFlush 的累积 + flush 都在 main actor (TaskGroup
        // body 是 main actor isolated, 各 task 完成回到这里时是 serial 的),
        // 不需要锁。
        var iterator = snapshot.makeIterator()
        func nextEligibleSong() -> Song? {
            while let candidate = iterator.next() {
                if isStillEligible(candidate) {
                    return candidate
                }
            }
            return nil
        }
        func addTask(for song: Song, to group: inout TaskGroup<(song: Song, outcome: BackfillOutcome)>) {
            let limits = MetadataBackfillExecutionPolicy.limits(for: executionMode)
            let delay = limits.interRequestDelay
            let priority: TaskPriority = executionMode == .backgroundDuringPlayback
                ? .background
                : .utility
            group.addTask(priority: priority) { [self] in
                if delay > 0 {
                    do {
                        try await Task.sleep(for: .seconds(delay))
                    } catch {
                        return (
                            song,
                            BackfillOutcome(song: nil, markFailed: false, cancelled: true)
                        )
                    }
                }
                return (song, await self.processOne(song))
            }
        }
        await withTaskGroup(of: (song: Song, outcome: BackfillOutcome).self) { group in
            defer { group.cancelAll() }
            let initialLimits = MetadataBackfillExecutionPolicy.limits(for: executionMode)
            // Seed: background profiles deliberately launch one task only.
            for _ in 0..<initialLimits.workerCount {
                guard let song = nextEligibleSong() else { break }
                if shouldBlockForCellular() { return }
                addTask(for: song, to: &group)
            }

            // Drain: 每完成一个就启动下一个, 同时累积 / flush
            while let result = await group.next() {
                if Task.isCancelled { break }

                processedTotal += 1
                // UI progress does not need per-file granularity. Publishing
                // every ten results prevents an Observable invalidation storm
                // while retaining responsive feedback.
                if processedTotal.isMultiple(of: 10) || processedTotal == pendingCount {
                    processedCount = processedTotal
                }
                let songID = result.song.id
                let canRecordOutcome = isStillEligible(result.song)
                if result.outcome.sourceUnavailable, canRecordOutcome {
                    // A connection/authentication failure applies to the
                    // connector, not merely this 500-row snapshot. Park every
                    // unresolved row from the source so a large library emits
                    // one probe on this network path, not one probe per batch.
                    let sourceID = result.song.sourceID
                    let sourceSongIDs = Set(library.songs.lazy.filter { song in
                        song.sourceID == sourceID
                            && !self.failedSongIDs.contains(song.id)
                            && !self.sourceIssueSongIDs.contains(song.id)
                            && self.needsBackfill(song)
                    }.map(\.id))
                    let wasAlreadyParked = sourceSongIDs.isSubset(of: sessionNetworkParkedIDs)
                    sessionGivenUpIDs.formUnion(sourceSongIDs)
                    sessionNetworkParkedIDs.formUnion(sourceSongIDs)
                    let deferredIDs = MetadataBackfillDeferredRetryPolicy.idsToPersist(
                        failedSongID: songID,
                        snapshotSongIDs: sourceSongIDs,
                        cause: .sourceUnavailable
                    )
                    deferredRetrySongIDs.formUnion(deferredIDs)
                    if !deferredIDs.isEmpty { saveDeferredRetries() }
                    if !wasAlreadyParked {
                        let sourceAttempt = MetadataBackfillRetryPolicy.attemptCountAfterFailure(
                            currentCount: sourceTransientFailureCounts[sourceID] ?? 0
                        )
                        sourceTransientFailureCounts[sourceID] = sourceAttempt
                        saveRetryCounts()
                        let exhausted = MetadataBackfillRetryPolicy.hasExhaustedAutomaticAttempts(sourceAttempt)
                        plog("⚠️ Backfill: source \(sourceID) unavailable; parked \(sourceSongIDs.count) songs (attempt \(sourceAttempt), exhausted=\(exhausted))")
                    }
                }
                if result.outcome.markFailed, canRecordOutcome {
                    failedSongIDs.insert(songID)
                    incompleteSongIDs.remove(songID)
                    sourceIssueSongIDs.remove(songID)
                    deferredRetrySongIDs.remove(songID)
                    clearAutomaticRetryState(songID: songID, sourceID: result.song.sourceID)
                    saveFailed()
                    saveDeferredRetries()
                }
                if result.outcome.detailsIncomplete, canRecordOutcome {
                    incompleteSongIDs.insert(songID)
                    failedSongIDs.remove(songID)
                    sourceIssueSongIDs.remove(songID)
                    deferredRetrySongIDs.remove(songID)
                    clearAutomaticRetryState(songID: songID, sourceID: result.song.sourceID)
                    saveFailed()
                    saveDeferredRetries()
                }
                if result.outcome.sourceIssue, canRecordOutcome {
                    sourceIssueSongIDs.insert(songID)
                    failedSongIDs.remove(songID)
                    incompleteSongIDs.remove(songID)
                    deferredRetrySongIDs.remove(songID)
                    clearAutomaticRetryState(songID: songID, sourceID: result.song.sourceID)
                    saveFailed()
                    saveDeferredRetries()
                }
                if result.outcome.transientFailure,
                   MetadataBackfillRetryPolicy.shouldCountTransientFailure(
                    isCancellation: result.outcome.cancelled,
                    isTransient: result.outcome.transientFailure
                   ),
                   canRecordOutcome {
                    deferredRetrySongIDs.insert(songID)
                    sessionGivenUpIDs.insert(songID)
                    sessionNetworkParkedIDs.insert(songID)
                    let count = MetadataBackfillRetryPolicy.attemptCountAfterFailure(
                        currentCount: transientFailureCounts[songID] ?? 0
                    )
                    transientFailureCounts[songID] = count
                    saveDeferredRetries()
                    saveRetryCounts()
                    let exhausted = MetadataBackfillRetryPolicy.hasExhaustedAutomaticAttempts(count)
                    plog("⚠️ Backfill: '\(result.song.title)' deferred after transient failure (attempt \(count), exhausted=\(exhausted))")
                }
                if result.outcome.artworkGivenUp {
                    // Stop re-fetching this song for artwork, but DON'T fail it —
                    // its duration update below still flushes and it stays playable.
                    artworkGivenUpIDs.insert(songID)
                    saveArtworkGivenUp()
                }
                if result.outcome.titleInspected, canRecordOutcome {
                    markMetadataInspected(songID: songID)
                }
                if result.outcome.artistInspected, canRecordOutcome {
                    if result.outcome.song == nil {
                        markArtistInspected(songID: songID)
                    } else {
                        // Persist this only after the matching replacement is
                        // applied. Otherwise a process exit between the marker
                        // write and the library flush could strand an unknown
                        // artist that is no longer eligible for repair.
                        pendingArtistInspectionIDs.insert(songID)
                    }
                }
                if let updated = result.outcome.song {
                    clearAutomaticRetryState(songID: songID, sourceID: result.song.sourceID)
                    if !result.outcome.markFailed
                        && !result.outcome.detailsIncomplete
                        && !result.outcome.sourceIssue {
                        failedSongIDs.remove(songID)
                        incompleteSongIDs.remove(songID)
                        sourceIssueSongIDs.remove(songID)
                        sessionGivenUpIDs.remove(songID)
                        saveFailed()
                    }
                    pendingFlush.append(updated)
                }

                // Flush when the batch is full OR the interval has elapsed。
                // 在 main actor 上, library.replaceSongs 调一次即可。
                let flushInterval = MetadataBackfillExecutionPolicy
                    .limits(for: executionMode)
                    .flushInterval
                let shouldFlush = pendingFlush.count >= Self.flushBatchSize
                    || Date().timeIntervalSince(lastFlushAt) >= flushInterval
                if shouldFlush, !pendingFlush.isEmpty {
                    // Partial metadata can be accompanied by markFailed=true
                    // (for example TIT2 parsed but duration did not). Failure
                    // membership must stop future network retries, not discard
                    // the useful result we already have.
                    let batch = pendingFlush.compactMap(backfillResultForApply)
                    pendingFlush.removeAll(keepingCapacity: true)
                    lastFlushAt = Date()
                    if !batch.isEmpty {
                        library.replaceSongs(batch)
                        markArtistsInspected(
                            songIDs: pendingArtistInspectionIDs.intersection(batch.map(\.id))
                        )
                        pendingArtistInspectionIDs.subtract(batch.map(\.id))
                        clearDeferredRetries(in: batch)
                        markMetadataInspected(in: batch)
                        refreshRemainingCounts()
                        plog("📥 flushed \(batch.count) songs to library")
                    }
                }

                // Cellular check between songs ── 切到 cellular 后停止派发新
                // task, 已 in-flight 的让它们自然完成 (next 仍会 yield)。
                if shouldBlockForCellular() {
                    plog("📥 Backfill: cellular detected, stop dispatching new tasks")
                    continue
                }

                // 派发下一首给空闲 worker。
                if let next = nextEligibleSong() {
                    addTask(for: next, to: &group)
                }
            }
        }

        // Final flush
        if !pendingFlush.isEmpty {
            let batch = pendingFlush.compactMap(backfillResultForApply)
            pendingFlush.removeAll()
            if !batch.isEmpty {
                library.replaceSongs(batch)
                markArtistsInspected(
                    songIDs: pendingArtistInspectionIDs.intersection(batch.map(\.id))
                )
                clearDeferredRetries(in: batch)
                markMetadataInspected(in: batch)
                refreshRemainingCounts()
                plog("📥 final flush: \(batch.count) songs to library")
            }
        }
        // Also publish permanent/transient failures from a snapshot that had
        // no successful songs to flush.
        refreshRemainingCounts(force: true)
    }

    private func shouldBlockForCellular() -> Bool {
        let wifiOnly = UserDefaults.standard.object(forKey: Self.wifiOnlyDefaultsKey) as? Bool ?? true
        // 用户本次会话已明确同意蜂窝 → 不再拦。
        return wifiOnly && !cellularAllowedThisSession && !NetworkMonitor.shared.isOnUnmeteredNetwork
    }

    private func updateWaitingForWiFiState(presentPrompt: Bool) {
        let waiting = hasPendingWork && shouldBlockForCellular()
        if isWaitingForWiFi != waiting {
            isWaitingForWiFi = waiting
        }
        if presentPrompt {
            setCellularPromptPresented(waiting && !cellularPromptDismissedThisSession)
        } else if !waiting {
            setCellularPromptPresented(false)
        }
    }

    /// 用户在蜂窝提示里选择「继续」。persist=true 时永久关闭「仅 WiFi」开关,
    /// 否则只放行本次会话。随后立即恢复回填。
    func allowCellular(persist: Bool) {
        cellularAllowedThisSession = true
        if persist {
            UserDefaults.standard.set(false, forKey: Self.wifiOnlyDefaultsKey)
        }
        isWaitingForWiFi = false
        setCellularPromptPresented(false)
        resumeNetworkParkedWork()
        if worker == nil { start() }
    }

    /// 用户选择「仅 WiFi / 暂不」。本会话不再自动弹蜂窝提示。
    func dismissCellularPrompt() {
        cellularPromptDismissedThisSession = true
        setCellularPromptPresented(false)
    }

    /// 回填读取失败是否属于「瞬时、可重试」错误(连接/鉴权/超时/限流/网络/取消),
    /// 而非「永久」错误(文件已不存在、4xx 客户端错误)。瞬时错误不标 failed,
    /// 下一轮自动重试,避免重装/启动初期源未就绪时把歌永久钉成「无法读取」。
    static func isTransientBackfillError(_ error: Error) -> Bool {
        if error is BackfillHardTimeoutError { return true }
        if error is URLError { return true }
        if error is CancellationError { return true }
        switch error {
        case SourceError.connectionFailed, SourceError.credentialUnavailable,
             SourceError.authenticationFailed, SourceError.timeout:
            return true
        case SourceError.pathNotFound, SourceError.fileNotFound:
            return false // 文件确实不在了 —— 永久
        case CloudDriveError.notAuthenticated, CloudDriveError.tokenExpired,
             CloudDriveError.tokenRefreshFailed, CloudDriveError.rateLimited,
             CloudDriveError.invalidResponse, CloudDriveError.permissionDenied:
            return true
        case CloudDriveError.fileNotFound:
            return false
        case CloudDriveError.apiError(let code, _):
            // HTTP 408/425/429 are explicitly retryable. Provider body codes
            // may be negative, so they remain transient unless a connector
            // first maps a documented permanent code (such as Baidu -9) to
            // `fileNotFound`.
            return code < 0
                || code == 401
                || code == 403
                || code == 408
                || code == 425
                || code == 429
                || code >= 500
        default:
            return true // 未知的读取错误 → 当瞬时, 倾向重试而非永久卡死
        }
    }

    /// Connection-level failures affect an entire connector. They remain
    /// transient (never persisted as hundreds of bad songs), but trip the
    /// per-network-path source circuit breaker immediately.
    static func isSourceUnavailableBackfillError(_ error: Error) -> Bool {
        if error is BackfillHardTimeoutError
            || error is SourceConnectionTerminalError
            || error is URLError {
            return true
        }
        switch error {
        case SourceError.connectionFailed, SourceError.authenticationFailed,
             SourceError.credentialUnavailable, SourceError.timeout,
             CloudDriveError.notAuthenticated,
             CloudDriveError.credentialTemporarilyUnavailable,
             CloudDriveError.credentialReadFailed,
             CloudDriveError.tokenExpired,
             CloudDriveError.tokenRefreshFailed,
             CloudDriveError.tokenPersistenceFailed,
             CloudDriveError.permissionDenied,
             CloudDriveError.invalidResponse,
             CloudDriveError.rateLimited:
            return true
        case CloudDriveError.apiError(let code, _):
            return code < 0
                || code == 401
                || code == 403
                || code == 408
                || code == 425
                || code == 429
                || code >= 500
        default:
            return false
        }
    }

    /// Outcome of one backfill attempt. `song` is the merged result to
    /// flush into the library when present (preserves whatever fields we
    /// did parse, e.g. artist+album when duration was unreadable).
    /// `markFailed` tells the caller to add the original ID to
    /// `failedSongIDs` so backfill stops retrying — set even on partial
    /// merges so a duration-less file isn't picked up next pass.
    struct BackfillOutcome: Sendable {
        var song: Song?
        var markFailed: Bool
        /// Header bytes were read, but a dynamic/complete-file playback path
        /// can remain playable without a duration from this bounded parser.
        var detailsIncomplete: Bool = false
        /// The path/object could not be read and should be checked at the source.
        var sourceIssue: Bool = false
        /// The worker generation was cancelled. This is a neutral outcome.
        var cancelled: Bool = false
        /// A bounded header read completed, even if it yielded no replacement
        /// fields. This closes the independent title-inspection leg.
        var titleInspected: Bool = false
        /// The bounded region capable of containing track-artist text was read.
        /// This remains false when an expanded FLAC read fails, allowing a
        /// later network session to resume that specific inspection.
        var artistInspected: Bool = false
        /// Set when the attempt failed with a *transient* error (timeout /
        /// network / throttle). The caller records one persisted attempt and
        /// parks the song until a later network session.
        var transientFailure: Bool = false
        /// The connector cannot currently be used on this path (for example,
        /// the network timed out or an SMB password is missing). The caller
        /// parks every unresolved song from that source until another path.
        var sourceUnavailable: Bool = false
        /// Song parsed fine (has a usable duration) but has no extractable
        /// embedded artwork. Stop retrying it *for artwork* without marking it
        /// permanently failed — its duration update is still saved and it stays
        /// playable & recoverable.
        var artworkGivenUp: Bool = false
    }

    private struct BackfillHardTimeoutError: LocalizedError, Sendable {
        let seconds: TimeInterval

        var errorDescription: String? {
            String(
                format: String(localized: "error_metadata_tag_read_timeout %@"),
                String(seconds.finiteInt())
            )
        }
    }

    private final class AsyncTimeoutBox<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private let continuation: CheckedContinuation<T, Error>
        private var didFinish = false
        private var workTask: Task<Void, Never>?
        private var timeoutTask: Task<Void, Never>?

        init(_ continuation: CheckedContinuation<T, Error>) {
            self.continuation = continuation
        }

        func setTasks(workTask: Task<Void, Never>, timeoutTask: Task<Void, Never>) {
            lock.lock()
            if didFinish {
                lock.unlock()
                workTask.cancel()
                timeoutTask.cancel()
                return
            }
            self.workTask = workTask
            self.timeoutTask = timeoutTask
            lock.unlock()
        }

        func succeed(_ value: T) {
            finish(.success(value))
        }

        func fail(_ error: Error) {
            finish(.failure(error))
        }

        private func finish(_ result: Result<T, Error>) {
            let tasks: (work: Task<Void, Never>?, timeout: Task<Void, Never>?)
            lock.lock()
            if didFinish {
                lock.unlock()
                return
            }
            didFinish = true
            tasks = (workTask, timeoutTask)
            lock.unlock()

            tasks.work?.cancel()
            tasks.timeout?.cancel()

            switch result {
            case .success(let value):
                continuation.resume(returning: value)
            case .failure(let error):
                continuation.resume(throwing: error)
            }
        }
    }

    private nonisolated static func withHardTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            let box = AsyncTimeoutBox<T>(continuation)
            let timeoutNanoseconds = (max(0.1, seconds) * 1_000_000_000)
                .finiteUInt64(or: 100_000_000)

            let workTask = Task {
                do {
                    box.succeed(try await operation())
                } catch {
                    box.fail(error)
                }
            }

            let timeoutTask = Task {
                do {
                    try await Task.sleep(nanoseconds: timeoutNanoseconds)
                    box.fail(BackfillHardTimeoutError(seconds: seconds))
                } catch {
                    // The timeout task is cancelled when work finishes first.
                }
            }

            box.setTasks(workTask: workTask, timeoutTask: timeoutTask)
        }
    }

    /// Run one backfill against `song`. Returns a merged Song to flush
    /// (may be nil if extraction yielded nothing usable) and a flag
    /// indicating whether the attempt should be remembered as failed —
    /// the two are independent because some files parse partial tags
    /// (artist, album) but never expose duration.
    private func processOne(_ song: Song) async -> BackfillOutcome {
        let started = Date()
        do {
            return try await Self.withHardTimeout(seconds: Self.perSongTimeout) { [self] in
                try await self.processOneCore(song, started: started)
            }
        } catch {
            let elapsed = Date().timeIntervalSince(started)
            if !isStillEligible(song) {
                return BackfillOutcome(song: nil, markFailed: false)
            }
            let cancelled = error is CancellationError || Task.isCancelled
            if cancelled {
                plog("📥 Backfill: cancelled '\(song.title)' without consuming a retry")
                return BackfillOutcome(
                    song: nil,
                    markFailed: false,
                    cancelled: true
                )
            }
            // 只有「确定性永久」的错误(文件已不存在 / 4xx)才标记 failed —— 那种
            // 重试也没用,标记后不再浪费配额。连接/鉴权/超时/限流/网络这类是瞬时的
            // (常见于刚启动、源还没连上 / token 还没就绪),绝不能钉成永久失败,否则
            // 会一直卡在「无法读取歌曲详情」;不标记 → 下一轮回填自动重试。
            let transient = Self.isTransientBackfillError(error)
            let sourceUnavailable = Self.isSourceUnavailableBackfillError(error)
            plog(String(format: "⚠️ Backfill failed for '%@' after %.2fs: %@ (%@)",
                        song.title, elapsed, error.localizedDescription,
                        transient ? "transient — will retry" : "permanent — marking failed"))
            return BackfillOutcome(
                song: nil,
                markFailed: false,
                sourceIssue: !transient,
                transientFailure: transient,
                sourceUnavailable: sourceUnavailable
            )
        }
    }

    private func processOneCore(_ song: Song, started: Date) async throws -> BackfillOutcome {
        guard isStillEligible(song) else {
            return BackfillOutcome(song: nil, markFailed: false)
        }
        // Use the SHARED connector (not auxiliary). Backfill is sequential
        // and benefits massively from accumulated state on the single
        // BaiduPanSource actor: throttle clock, dlink cache, dir-listing
        // cache. Auxiliary instances reset all of that per song, which is
        // what made backfill 10x slower than it needed to be — every song
        // re-paid the list+filemetas dlink cost AND was prone to 31034
        // rate-limit storms because the throttle state didn't carry over.
        let fetchStarted = Date()
        let headData = try await sourceManager.fetchMetadataRange(
            for: song,
            offset: 0,
            length: Self.headBytes
        )
        let fetchElapsed = Date().timeIntervalSince(fetchStarted)

        // Do not turn metadata backfill into a whole-library playback-cache
        // prewarm. At 256 KB per song, a 10K-song source caused ~2.5 GB of
        // unnecessary writes and sustained I/O pressure while the user was
        // browsing. Playback already prewarms the current song and queue on
        // demand through SourceManager.

        var metadataInputData = headData
        var metadata = await extractMetadata(
            from: headData,
            song: song,
            cacheKey: song.id
        )
        let needsArtistInspection = (song.artistName?
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            && !artistCheckedIDs.contains(song.id)
        var artistInspectionCompleted = !needsArtistInspection
            || metadata.artist?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        if song.fileFormat == .mp3 {
            let id3ByteCount = FileMetadataReader.id3TagByteCount(in: headData)
            let hasTruncatedID3 = (id3ByteCount ?? 0) > headData.count
            let needsDurationExpansion = metadataLooksMissing(metadata)
            let needsArtworkExpansion = Self.needsEmbeddedArtworkBackfill(song)
                && metadata.coverArtFileName == nil
            let needsArtistExpansion = needsArtistInspection
                && metadata.artist?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
            let expandedByteCount = RemoteMetadataReadPolicy.expandedReadSize(
                fileSize: song.fileSize,
                currentByteCount: headData.count,
                declaredID3ByteCount: id3ByteCount,
                metadataInsufficient: needsDurationExpansion && !hasTruncatedID3
            ).map { min($0, Self.maxMetadataHeadBytes) } ?? headData.count
            if (needsDurationExpansion || needsArtworkExpansion || needsArtistExpansion),
               expandedByteCount > headData.count {
                do {
                    let expandedHead = try await sourceManager.fetchMetadataRange(
                        for: song,
                        offset: 0,
                        length: Int64(expandedByteCount)
                    )
                    metadataInputData = expandedHead
                    metadata = await extractMetadata(
                        from: expandedHead,
                        song: song,
                        cacheKey: song.id
                    )
                    if needsArtistExpansion,
                       metadata.artist?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                        artistInspectionCompleted = true
                    }
                } catch {
                    if needsArtistExpansion { throw error }
                }
            }
        } else if song.fileFormat == .flac,
                  needsArtistInspection,
                  metadata.artist?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            // STREAMINFO is normally in the first few bytes, while a valid
            // Vorbis-comment block can sit after large padding or artwork.
            // Retry only artist-less FLAC rows, cap the read at 4 MB, and let
            // the execution profile keep this extra traffic serial/throttled.
            let expandedByteCount = song.fileSize > 0
                ? RemoteMetadataReadPolicy.initialReadSize(
                    fileSize: song.fileSize,
                    fileExtension: song.fileFormat.rawValue
                )
                : Self.maxMetadataHeadBytes
            if expandedByteCount > headData.count {
                let expandedHead = try await sourceManager.fetchMetadataRange(
                    for: song,
                    offset: 0,
                    length: Int64(expandedByteCount)
                )
                metadataInputData = expandedHead
                metadata = await extractMetadata(
                    from: expandedHead,
                    song: song,
                    cacheKey: song.id
                )
            }
            artistInspectionCompleted = true
        } else if needsArtistInspection {
            artistInspectionCompleted = true
        }
        let lowercasedExtension = song.fileFormat.rawValue.lowercased()
        let needsSecondaryArtistRange = needsArtistInspection
            && metadata.artist?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
            && (Self.isoBaseMediaExtensions.contains(lowercasedExtension)
                || lowercasedExtension == "mp3")
        if metadataLooksMissing(metadata) || needsSecondaryArtistRange {
            if Self.isoBaseMediaExtensions.contains(lowercasedExtension) {
                var readContainerTail = false
                for tailSize in RemoteMetadataReadPolicy.containerTailReadSizes(fileSize: song.fileSize) {
                    do {
                        let tailData = try await sourceManager.fetchMetadataRange(
                            for: song,
                            offset: -Int64(tailSize),
                            length: Int64(tailSize)
                        )
                        guard !tailData.isEmpty else { continue }
                        readContainerTail = true
                        metadata = await extractMetadata(
                            from: metadataInputData,
                            containerTailData: tailData,
                            song: song,
                            cacheKey: song.id
                        )
                        let foundArtist = metadata.artist?
                            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                        if !metadataLooksMissing(metadata)
                            && (!needsSecondaryArtistRange || foundArtist) {
                            break
                        }
                    } catch {
                        if needsSecondaryArtistRange { throw error }
                    }
                }
                if needsSecondaryArtistRange, readContainerTail {
                    artistInspectionCompleted = true
                }
            } else if lowercasedExtension == "mp3" {
                do {
                    let tailData = try await sourceManager.fetchMetadataRange(
                        for: song,
                        offset: -Self.fallbackTailBytes,
                        length: Self.fallbackTailBytes
                    )
                    metadata = await extractMetadata(
                        from: metadataInputData,
                        id3TailData: tailData,
                        song: song,
                        cacheKey: song.id
                    )
                    if needsSecondaryArtistRange { artistInspectionCompleted = true }
                } catch {
                    if needsSecondaryArtistRange { throw error }
                }
            }
        }

        // Raw CBR MP3s and some OpenList-backed streams have valid MPEG frames
        // but no Xing/VBRI duration. FileMetadataReader still recovers their
        // bitrate from the bounded prefix, which is sufficient to estimate the
        // complete duration from the authoritative remote file size. This must
        // happen before the duration-missing failure gate below; the previous
        // correction ran afterwards and was therefore unreachable for exactly
        // these rows.
        if song.fileFormat == .mp3,
           metadata.duration <= 0 {
            let estimated = RemoteMetadataReadPolicy.correctedMP3Duration(
                parsed: metadata.duration,
                fileSize: song.fileSize,
                bitRateKbps: metadata.bitRate,
                providedByteCount: metadataInputData.count,
                leadingMetadataByteCount: FileMetadataReader.id3TagByteCount(in: metadataInputData) ?? 0
            )
            if estimated > 0 {
                metadata.duration = estimated
                plog(String(format: "📥 Backfill: '%@' recovered MP3 duration %.1fs from bounded metadata and file size", song.title, estimated))
            }
        }

        // Duration can fail independently from the ID3 text frames. Preserve
        // any title/artist/album/cover we did recover, then mark the row failed
        // only to stop repeated network reads. Older code returned nil here,
        // so a valid TIT2 was silently thrown away and the filename remained
        // visible until an online scrape replaced the song.
        if metadataLooksMissing(metadata) {
            if hasUsablePartialMetadata(metadata, comparedTo: song) {
                let partial = mergeSong(bare: song, metadata: metadata)
                plog("⚠️ Backfill: '\(song.title)' has no duration after head+tail; saving verified partial tags as '\(partial.title)'")
                return BackfillOutcome(
                    song: partial,
                    markFailed: false,
                    detailsIncomplete: true,
                    titleInspected: true,
                    artistInspected: artistInspectionCompleted
                )
            }
            if song.isStreamDescriptor || song.fileFormat.requiresFFmpeg {
                plog("📥 Backfill: '\(song.title)' remains playable with incomplete bounded metadata")
                return BackfillOutcome(
                    song: nil,
                    markFailed: false,
                    detailsIncomplete: true,
                    titleInspected: true,
                    artistInspected: artistInspectionCompleted
                )
            }
            plog("⚠️ Backfill: '\(song.title)' bytes were read but details parsing failed")
            return BackfillOutcome(
                song: nil,
                markFailed: true,
                titleInspected: true,
                artistInspected: artistInspectionCompleted
            )
        }

        // After tightening `metadataLooksMissing` to require
        // duration > 0, reaching this point means head+tail
        // produced a usable duration. The old "merged.duration<=0
        // → markFailed" guard was firing on songs that just hadn't
        // had tail tried yet — removed.
        // Only reverse-compute for raw MP3. M4A/MP4/M4B carry
        // authoritative duration inside `moov.mvhd`; backfill's
        // tail-fetch already gets it correctly. Applying the
        // bytes-÷-bitrate heuristic to those formats wrongly
        // overwrites the correct value because m4a containers
        // often wrap data far larger than `bitRate × duration / 8`
        // (multiple tracks, padding, sidecar metadata) — observed
        // in the field as a 13MB / 198kbps m4a being "corrected"
        // from the real 177s to a bogus 562s.
        let ext = song.fileFormat.rawValue
        if ext == "mp3" {
            let originalDuration = metadata.duration
            metadata.duration = RemoteMetadataReadPolicy.correctedMP3Duration(
                parsed: metadata.duration,
                fileSize: song.fileSize,
                bitRateKbps: metadata.bitRate,
                providedByteCount: metadataInputData.count,
                leadingMetadataByteCount: FileMetadataReader.id3TagByteCount(in: metadataInputData) ?? 0
            )
            if metadata.duration != originalDuration {
                plog(String(format: "📥 Backfill: '%@' duration estimate %.1fs → %.1fs", song.title, originalDuration, metadata.duration))
            }
        } else if ext == "flac",
                  (metadata.bitRate ?? 0) <= 0,
                  metadata.duration > 0,
                  song.fileSize > 0 {
            metadata.bitRate = (Double(song.fileSize) * 8.0 / metadata.duration / 1000.0)
                .rounded()
                .finiteInt()
        }
        let merged = mergeSong(bare: song, metadata: metadata)
        let artworkStillMissing = Self.needsEmbeddedArtworkBackfill(song)
            && (merged.coverArtFileName?.isEmpty ?? true)
        let totalElapsed = Date().timeIntervalSince(started)
        // Include the parsed duration in the log line so an
        // infinite-loop case (pickNextBatch repeatedly handing back
        // the same songs) can be diagnosed without re-instrumenting:
        // duration=0 in the log means mergeSong didn't actually
        // capture a usable duration despite metadataLooksMissing
        // returning false → bug in the parser or the gate.
        plog(String(format: "📥 Backfill: '%@' done in %.2fs (fetch %.2fs) duration=%.1fs", song.title, totalElapsed, fetchElapsed, merged.duration))
        if artworkStillMissing {
            plog("📥 Backfill: '\(song.title)' has no parseable MP3 artwork; skipping future artwork-only retries")
        }
        // Missing artwork must NOT mark the song permanently failed — that
        // dropped its (just-parsed) duration at flush and stuck it bare. Keep
        // the duration, record the artwork give-up separately.
        return BackfillOutcome(
            song: merged,
            markFailed: false,
            titleInspected: true,
            artistInspected: artistInspectionCompleted,
            artworkGivenUp: artworkStillMissing
        )
    }

    /// Parse the bounded Range bytes directly from memory. Backfill keeps its
    /// established three-worker cap, while FileMetadataReader serializes the
    /// small AVFoundation range responses; the caller-owned Data is released
    /// at this per-song boundary instead of being copied into a temp file.
    private func extractMetadata(
        from data: Data,
        containerTailData: Data? = nil,
        id3TailData: Data? = nil,
        song: Song,
        cacheKey: String
    ) async -> MetadataService.SongMetadata {
        let ext = song.fileFormat.rawValue
        let pathTitle = MediaMetadataTextRepair.fileNameTitle(from: song.filePath)
        let fallbackTitle = MediaMetadataTextRepair.preferred(
            embedded: song.title,
            fromFileName: pathTitle
        ) ?? song.title
        return await metadataService.loadEmbeddedMetadata(
            from: data,
            containerTailData: containerTailData,
            id3TailData: id3TailData,
            fileExtension: ext,
            cacheKey: cacheKey,
            fallbackTitle: fallbackTitle
        )
    }

    private func metadataLooksMissing(_ m: MetadataService.SongMetadata) -> Bool {
        // Duration is the load-bearing field — without it the player
        // can't draw a progress bar and SFB streaming may decide the
        // song is shorter than it actually is. We treat duration alone
        // as the signal for "head fetch was insufficient, try tail".
        //
        // Why ignore artist/album: M4A/MP4/M4B commonly put `udta`
        // (artist/album tags) in the head but `moov` (which carries
        // duration via `mvhd`/`mdhd`) at the tail. The old rule only
        // fired tail-fetch when ALL of artist/album/duration were
        // missing — so these files passed with duration=0 and got
        // marked failed downstream. Failing on missing duration alone
        // costs one extra Range request for the small minority of
        // files that don't expose duration in head, and recovers the
        // common case where tail has it.
        m.duration <= 0
    }

    private func hasUsablePartialMetadata(
        _ metadata: MetadataService.SongMetadata,
        comparedTo song: Song
    ) -> Bool {
        let incomingTitle = metadata.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentTitle = song.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return (!incomingTitle.isEmpty && incomingTitle != currentTitle)
            || metadata.artist != nil
            || metadata.albumTitle != nil
            || metadata.albumArtist != nil
            || metadata.trackNumber != nil
            || metadata.discNumber != nil
            || metadata.year != nil
            || metadata.genre != nil
            || metadata.sampleRate != nil
            || metadata.bitRate != nil
            || metadata.bitDepth != nil
            || metadata.coverArtFileName != nil
            || metadata.lyricsFileName != nil
            || metadata.replayGainTrackGain != nil
            || metadata.replayGainTrackPeak != nil
            || metadata.replayGainAlbumGain != nil
            || metadata.replayGainAlbumPeak != nil
    }

    private func mergeSong(bare: Song, metadata: MetadataService.SongMetadata) -> Song {
        let metadataTitle = metadata.title.trimmingCharacters(in: .whitespacesAndNewlines)
        // 文件名是一条独立于内嵌标签的来源, 且通常更可信 —— 详见
        // MediaMetadataTextRepair.preferred。之前这里只要标签非空就无条件
        // 覆盖 bare.title(文件名), 于是标签解码猜错时, 乱码盖掉了好数据。
        let pathTitle = MediaMetadataTextRepair.fileNameTitle(from: bare.filePath)
        let nameTitle = MediaMetadataTextRepair.preferred(
            embedded: bare.title,
            fromFileName: pathTitle
        ) ?? bare.title
        let nameArtist = MediaMetadataTextRepair.fileNameArtist(from: bare.filePath)

        // A CUE track's text belongs to the virtual track. Embedded tags in
        // the referenced image describe the whole album and must not replace
        // every track with the same title/track number.
        let mergedTitle = bare.isCueTrack
            ? bare.title
            : (MediaMetadataTextRepair.preferred(
                embedded: metadataTitle.isEmpty ? nil : metadata.title,
                fromFileName: nameTitle
              ) ?? bare.title)
        let mergedArtist = bare.isCueTrack
            ? (bare.artistName ?? metadata.artist)
            : (MediaMetadataTextRepair.preferred(
                embedded: metadata.artist,
                fromFileName: nameArtist
              ) ?? bare.artistName)
        // 专辑名没有文件名兜底源 —— 目录名不可靠(常是 "音乐"、"新建文件夹"),
        // 拿它冒充专辑比留着乱码更糟。这里只做取舍不做替换。
        let mergedAlbum = bare.isCueTrack
            ? (bare.albumTitle ?? metadata.albumTitle)
            : (metadata.albumTitle ?? bare.albumTitle)
        let mergedAlbumArtist = AlbumGroupingPolicy.resolvedAlbumArtistName(
            albumArtistName: bare.isCueTrack
                ? (bare.albumArtistName ?? metadata.albumArtist)
                : (metadata.albumArtist ?? bare.albumArtistName),
            trackArtistName: mergedArtist
        )
        let artistID = mergedArtist.map { Self.hash($0.lowercased()) }
        let albumID: String? = if let albumArtist = mergedAlbumArtist, let album = mergedAlbum {
            Self.hash("\(albumArtist.lowercased()):\(album.lowercased())")
        } else {
            nil
        }

        // Sidecar references on the bare song (from listFiles sibling
        // detection) win over anything embedded in the file — they're
        // higher quality (full-size cover) and remote-resolvable.
        let coverRef = bare.coverArtFileName ?? metadata.coverArtFileName
        let lyricsRef = bare.lyricsFileName ?? metadata.lyricsFileName
        let mvRef = bare.mvPath ?? metadata.mvPath

        let mergedDuration: TimeInterval = if bare.isCueTrack,
                                              let start = bare.cueStartTime {
            max(0, (bare.cueEndTime ?? metadata.duration) - start)
        } else {
            metadata.duration > 0 ? metadata.duration : bare.duration
        }

        let merged = Song(
            id: bare.id,
            title: mergedTitle,
            albumID: albumID,
            artistID: artistID,
            albumTitle: mergedAlbum,
            artistName: mergedArtist,
            albumArtistName: mergedAlbumArtist,
            trackNumber: bare.isCueTrack ? bare.trackNumber : (metadata.trackNumber ?? bare.trackNumber),
            discNumber: metadata.discNumber ?? bare.discNumber,
            duration: mergedDuration,
            fileFormat: bare.fileFormat,
            filePath: bare.filePath,
            sourceID: bare.sourceID,
            fileSize: bare.fileSize,
            bitRate: metadata.bitRate ?? bare.bitRate,
            sampleRate: metadata.sampleRate ?? bare.sampleRate,
            bitDepth: metadata.bitDepth ?? bare.bitDepth,
            genre: metadata.genre ?? bare.genre,
            year: metadata.year ?? bare.year,
            lastModified: bare.lastModified,
            dateAdded: bare.dateAdded,
            coverArtFileName: coverRef,
            lyricsFileName: lyricsRef,
            mvPath: mvRef,
            replayGainTrackGain: metadata.replayGainTrackGain ?? bare.replayGainTrackGain,
            replayGainTrackPeak: metadata.replayGainTrackPeak ?? bare.replayGainTrackPeak,
            replayGainAlbumGain: metadata.replayGainAlbumGain ?? bare.replayGainAlbumGain,
            replayGainAlbumPeak: metadata.replayGainAlbumPeak ?? bare.replayGainAlbumPeak,
            cueSheetPath: bare.cueSheetPath,
            cueStartTime: bare.cueStartTime,
            cueEndTime: bare.cueEndTime,
            revision: bare.revision,
            titlePinyin: mergedTitle == bare.title ? bare.titlePinyin : nil,
            artistPinyin: mergedArtist == bare.artistName ? bare.artistPinyin : nil,
            albumPinyin: mergedAlbum == bare.albumTitle ? bare.albumPinyin : nil,
            lyricsText: bare.lyricsText,
            userMetadataEditedAt: bare.userMetadataEditedAt
        )
        return SongUserMetadataPolicy.preservingUserEdits(from: bare, in: merged)
    }

    // MARK: - Queue selection

    /// A song needs backfill if it has none of the metadata that file-header
    /// extraction would produce (duration, bitRate). Songs in the failure
    /// set are skipped. Limited to a batch so the queue doesn't grow
    /// unbounded for huge libraries.
    private func pickNextBatch(limit: Int) -> [Song] {
        let sourceIDs = backfillableSourceIDs()
        let failedIDs = failedSongIDs
        let sourceIssueIDs = sourceIssueSongIDs
        let sessionGivenUpSnapshot = sessionGivenUpIDs
        let retryCountSnapshot = transientFailureCounts
        let sourceRetryCountSnapshot = sourceTransientFailureCounts
        let disabledSourceIDs = library.disabledSourceIDs
        let artworkGivenUpSnapshot = artworkGivenUpIDs
        let titleCheckedSnapshot = titleCheckedIDs
        let albumArtistCheckedSnapshot = albumArtistCheckedIDs
        let artistCheckedSnapshot = artistCheckedIDs
        let incompleteSnapshot = incompleteSongIDs
        let songs = library.songs
        let candidates = songs.lazy.filter { song in
            guard !failedIDs.contains(song.id) else { return false }
            guard !sourceIssueIDs.contains(song.id) else { return false }
            guard !sessionGivenUpSnapshot.contains(song.id) else { return false }
            guard !Self.automaticRetriesExhausted(
                songID: song.id,
                sourceID: song.sourceID,
                retryCounts: retryCountSnapshot,
                sourceRetryCounts: sourceRetryCountSnapshot
            ) else { return false }
            guard !disabledSourceIDs.contains(song.sourceID) else { return false }
            guard sourceIDs.contains(song.sourceID) else { return false }
            return Self.needsBackfill(
                song,
                artworkGivenUpIDs: artworkGivenUpSnapshot,
                titleCheckedIDs: titleCheckedSnapshot,
                incompleteSongIDs: incompleteSnapshot,
                albumArtistCheckedIDs: albumArtistCheckedSnapshot,
                artistCheckedIDs: artistCheckedSnapshot
            )
        }
        return Array(candidates.prefix(max(1, limit)))
    }

    private func isStillEligible(_ song: Song) -> Bool {
        guard !failedSongIDs.contains(song.id) else { return false }
        guard !sourceIssueSongIDs.contains(song.id) else { return false }
        guard !sessionGivenUpIDs.contains(song.id) else { return false }
        guard !Self.automaticRetriesExhausted(
            songID: song.id,
            sourceID: song.sourceID,
            retryCounts: transientFailureCounts,
            sourceRetryCounts: sourceTransientFailureCounts
        ) else { return false }
        guard !library.disabledSourceIDs.contains(song.sourceID) else { return false }
        guard backfillableSourceIDs().contains(song.sourceID) else { return false }
        guard let live = library.song(id: song.id), live.sourceID == song.sourceID else { return false }
        return self.needsBackfill(live)
    }

    /// Validate that an in-flight result still belongs to the live file. This
    /// deliberately ignores failedSongIDs: a partial result is marked failed
    /// before the coalesced flush, but its already-parsed tags must still land.
    private func backfillResultForApply(_ song: Song) -> Song? {
        guard !library.disabledSourceIDs.contains(song.sourceID) else { return nil }
        guard backfillableSourceIDs().contains(song.sourceID) else { return nil }
        guard let live = library.song(id: song.id),
              live.sourceID == song.sourceID,
              live.filePath == song.filePath else {
            return nil
        }
        if let liveRevision = live.revision, let resultRevision = song.revision {
            guard liveRevision == resultRevision else { return nil }
        }
        if live.fileSize > 0, song.fileSize > 0 {
            guard live.fileSize == song.fileSize else { return nil }
        }
        return SongUserMetadataPolicy.preservingUserEdits(from: live, in: song)
    }

    /// A song still needs backfill if it's bare (no duration), or it's an MP3
    /// missing a cover that we haven't already given up on for artwork. The
    /// artwork-give-up check keeps a duration-complete song from being re-picked
    /// forever just because its file has no embedded cover.
    private func needsBackfill(_ song: Song) -> Bool {
        Self.needsBackfill(
            song,
            artworkGivenUpIDs: artworkGivenUpIDs,
            titleCheckedIDs: titleCheckedIDs,
            incompleteSongIDs: incompleteSongIDs,
            albumArtistCheckedIDs: albumArtistCheckedIDs,
            artistCheckedIDs: artistCheckedIDs
        )
    }

    private static func needsBackfill(
        _ song: Song,
        artworkGivenUpIDs: Set<String>,
        titleCheckedIDs: Set<String>,
        incompleteSongIDs: Set<String>,
        albumArtistCheckedIDs: Set<String>,
        artistCheckedIDs: Set<String>
    ) -> Bool {
        MetadataBackfillEligibilityPolicy.needsBackfill(
            duration: song.duration,
            format: song.fileFormat,
            hasCoverArt: !(song.coverArtFileName?.isEmpty ?? true),
            artworkGivenUp: artworkGivenUpIDs.contains(song.id),
            titleChecked: titleCheckedIDs.contains(song.id),
            durationInspectionComplete: incompleteSongIDs.contains(song.id),
            hasAlbumTitle: !(song.albumTitle?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true),
            hasAlbumArtist: !(song.albumArtistName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true),
            albumArtistChecked: albumArtistCheckedIDs.contains(song.id),
            hasArtist: !(song.artistName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true),
            artistChecked: artistCheckedIDs.contains(song.id)
        )
    }

    private static func needsEmbeddedArtworkBackfill(_ song: Song) -> Bool {
        song.fileFormat == .mp3 && (song.coverArtFileName?.isEmpty ?? true)
    }

    private static func automaticRetriesExhausted(
        songID: String,
        sourceID: String,
        retryCounts: [String: Int],
        sourceRetryCounts: [String: Int]
    ) -> Bool {
        MetadataBackfillRetryPolicy.hasExhaustedAutomaticAttempts(retryCounts[songID] ?? 0)
            || MetadataBackfillRetryPolicy.hasExhaustedAutomaticAttempts(sourceRetryCounts[sourceID] ?? 0)
    }

    // MARK: - Failed-set persistence

    private func loadFailed() {
        guard let data = try? Data(contentsOf: failedURL),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else { return }
        failedSongIDs = Set(decoded)
    }

    private func loadIncomplete() {
        guard let data = try? Data(contentsOf: incompleteURL),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else { return }
        incompleteSongIDs = Set(decoded)
    }

    private func loadSourceIssues() {
        guard let data = try? Data(contentsOf: sourceIssueURL),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else { return }
        sourceIssueSongIDs = Set(decoded)
    }

    private func loadArtworkGivenUp() {
        guard let data = try? Data(contentsOf: artworkGivenUpURL),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else { return }
        artworkGivenUpIDs = Set(decoded)
    }

    private func loadTitleChecked() {
        guard let data = try? Data(contentsOf: titleCheckedURL),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else { return }
        titleCheckedIDs = Set(decoded)
    }

    private func loadAlbumArtistChecked() {
        guard let data = try? Data(contentsOf: albumArtistCheckedURL),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else { return }
        albumArtistCheckedIDs = Set(decoded)
    }

    private func loadArtistChecked() {
        guard let data = try? Data(contentsOf: artistCheckedURL),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else { return }
        artistCheckedIDs = Set(decoded)
    }

    private func loadDeferredRetries() {
        guard let data = try? Data(contentsOf: deferredRetryURL),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else { return }
        deferredRetrySongIDs = Set(decoded)
    }

    private func loadRetryCounts() {
        guard let data = try? Data(contentsOf: retryCountsURL),
              let decoded = try? JSONDecoder().decode([String: Int].self, from: data) else { return }
        transientFailureCounts = Self.sanitizedRetryCounts(decoded)
    }

    private func loadSourceRetryCounts() {
        guard let data = try? Data(contentsOf: sourceRetryCountsURL),
              let decoded = try? JSONDecoder().decode([String: Int].self, from: data) else { return }
        sourceTransientFailureCounts = Self.sanitizedRetryCounts(decoded)
    }

    private nonisolated static func sanitizedRetryCounts(
        _ counts: [String: Int]
    ) -> [String: Int] {
        counts.reduce(into: [:]) { result, entry in
            let (id, count) = entry
            guard !id.isEmpty, count > 0 else { return }
            result[id] = min(count, MetadataBackfillRetryPolicy.maximumAutomaticAttempts)
        }
    }

    private func saveArtworkGivenUp() {
        scheduleStatePersistence()
    }

    private func saveTitleChecked() {
        saveInspectionState()
    }

    private func saveInspectionState() {
        scheduleStatePersistence()
    }

    private func saveDeferredRetries() {
        scheduleStatePersistence()
    }

    private func saveRetryCounts() {
        scheduleStatePersistence()
    }

    private func clearDeferredRetries(in songs: [Song]) {
        let previousCount = deferredRetrySongIDs.count
        deferredRetrySongIDs.subtract(songs.map(\.id))
        if deferredRetrySongIDs.count != previousCount {
            saveDeferredRetries()
        }
    }

    private func markMetadataInspected(songID: String) {
        let titleInserted = titleCheckedIDs.insert(songID).inserted
        let albumArtistInserted = albumArtistCheckedIDs.insert(songID).inserted
        if titleInserted || albumArtistInserted {
            saveInspectionState()
        }
    }

    private func markArtistInspected(songID: String) {
        markArtistsInspected(songIDs: [songID])
    }

    private func markArtistsInspected(songIDs: Set<String>) {
        guard !songIDs.isEmpty else { return }
        let previousCount = artistCheckedIDs.count
        artistCheckedIDs.formUnion(songIDs)
        guard artistCheckedIDs.count != previousCount else { return }
        saveInspectionState()
    }

    private func markMetadataInspected(in songs: [Song]) {
        let ids = songs.map(\.id)
        let previousTitleCount = titleCheckedIDs.count
        let previousAlbumArtistCount = albumArtistCheckedIDs.count
        titleCheckedIDs.formUnion(ids)
        albumArtistCheckedIDs.formUnion(ids)
        if titleCheckedIDs.count != previousTitleCount
            || albumArtistCheckedIDs.count != previousAlbumArtistCount {
            saveInspectionState()
        }
    }

    private func clearAutomaticRetryState(songID: String, sourceID: String) {
        sessionGivenUpIDs.remove(songID)
        sessionNetworkParkedIDs.remove(songID)
        sessionStallParkedIDs.remove(songID)
        let songCountRemoved = transientFailureCounts.removeValue(forKey: songID) != nil
        let sourceCountRemoved = sourceTransientFailureCounts.removeValue(forKey: sourceID) != nil
        if songCountRemoved || sourceCountRemoved {
            saveRetryCounts()
        }
    }

    private func saveFailed() {
        scheduleStatePersistence()
    }

    private func scheduleStatePersistence() {
        // Set snapshots are copy-on-write, so capturing them here is cheap.
        // Conversion to arrays, JSON encoding, and disk writes happen later on
        // a utility executor. Repeated per-song updates collapse into one write.
        let failed = failedSongIDs
        let incomplete = incompleteSongIDs
        let sourceIssues = sourceIssueSongIDs
        let artworkGivenUp = artworkGivenUpIDs
        let titleChecked = titleCheckedIDs
        let albumArtistChecked = albumArtistCheckedIDs
        let artistChecked = artistCheckedIDs
        let deferredRetries = deferredRetrySongIDs
        let retryCounts = transientFailureCounts
        let sourceRetryCounts = sourceTransientFailureCounts
        let failedURL = failedURL
        let incompleteURL = incompleteURL
        let sourceIssueURL = sourceIssueURL
        let artworkURL = artworkGivenUpURL
        let titleURL = titleCheckedURL
        let albumArtistURL = albumArtistCheckedURL
        let artistURL = artistCheckedURL
        let deferredRetryURL = deferredRetryURL
        let retryCountsURL = retryCountsURL
        let sourceRetryCountsURL = sourceRetryCountsURL

        statePersistenceTask?.cancel()
        statePersistenceTask = Task.detached(priority: .utility) {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            Self.writeIDSet(failed, to: failedURL)
            Self.writeIDSet(incomplete, to: incompleteURL)
            Self.writeIDSet(sourceIssues, to: sourceIssueURL)
            Self.writeIDSet(artworkGivenUp, to: artworkURL)
            Self.writeIDSet(titleChecked, to: titleURL)
            Self.writeIDSet(albumArtistChecked, to: albumArtistURL)
            Self.writeIDSet(artistChecked, to: artistURL)
            Self.writeIDSet(deferredRetries, to: deferredRetryURL)
            Self.writeRetryCounts(retryCounts, to: retryCountsURL)
            Self.writeRetryCounts(sourceRetryCounts, to: sourceRetryCountsURL)
        }
    }

    private nonisolated static func writeIDSet(_ ids: Set<String>, to url: URL) {
        guard let data = try? JSONEncoder().encode(Array(ids)) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private nonisolated static func writeRetryCounts(_ counts: [String: Int], to url: URL) {
        guard let data = try? JSONEncoder().encode(counts) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private static func hash(_ input: String) -> String {
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}
